import Foundation
import Network
import UniSpaceDomain

public struct PairingCandidate: Identifiable, Sendable {
    public let id: DeviceID
    public let name: String
    let endpoint: NWEndpoint
    let offer: PairingOffer

    init(id: DeviceID, name: String, endpoint: NWEndpoint, offer: PairingOffer) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.offer = offer
    }
}

public struct PairingPrompt: Equatable, Sendable {
    public let peer: DeviceDescriptor
    public let code: String

    public init(peer: DeviceDescriptor, code: String) {
        self.peer = peer
        self.code = code
    }
}

public enum PairingServiceError: Error, LocalizedError {
    case notReady
    case malformedMessage
    case peerRejected
    case workspaceFull
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notReady: "Pairing is not ready."
        case .malformedMessage: "The pairing message was invalid."
        case .peerRejected: "The other Mac rejected pairing."
        case .workspaceFull: "A UniSpace workspace supports up to four Macs."
        case let .network(message): message
        }
    }
}

public final class PairingNetworkService: @unchecked Sendable {
    public static let serviceType = "_unispace-pair._tcp"

    public var candidatesHandler: (@Sendable ([PairingCandidate]) -> Void)?
    public var promptHandler: (@Sendable (PairingPrompt) -> Void)?
    public var joinedHandler: (@Sendable (WorkspaceSnapshot, Data) -> Void)?
    public var hostUpdatedHandler: (@Sendable (WorkspaceSnapshot) -> Void)?
    public var failureHandler: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "com.layatai.unispace.pairing", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var crypto: PairingCryptoSession?
    private var channel: PairingChannel?
    private var workspace: WorkspaceSnapshot?
    private var workspaceKey: Data?
    private var localDevice: DeviceDescriptor?
    private var peerDevice: DeviceDescriptor?
    private var peerOffer: PairingOffer?
    private var localConfirmed = false
    private var peerConfirmed = false
    private var isHost = false

    public init() {}

    public func startHosting(workspace: WorkspaceSnapshot, key: Data, localDevice: DeviceDescriptor) throws {
        guard workspace.devices.count < 4 else { throw PairingServiceError.workspaceFull }
        stop()
        let crypto = PairingCryptoSession()
        let listener = try NWListener(using: .tcp, on: .any)
        let record = NWTXTRecord([
            "device": localDevice.id.rawValue.uuidString,
            "name": localDevice.name,
            "publicKey": crypto.offer.publicKey.base64EncodedString(),
            "nonce": crypto.offer.nonce.base64EncodedString(),
            "version": "1"
        ])
        listener.service = NWListener.Service(name: localDevice.name, type: Self.serviceType, txtRecord: record)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state { self?.fail(error.localizedDescription) }
        }
        lock.lock()
        self.crypto = crypto
        self.listener = listener
        self.workspace = workspace
        self.workspaceKey = key
        self.localDevice = localDevice
        self.isHost = true
        lock.unlock()
        listener.start(queue: queue)
    }

    public func startBrowsing() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.handleCandidates(results) }
        browser.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state { self?.fail(error.localizedDescription) }
        }
        lock.lock()
        self.browser = browser
        self.isHost = false
        lock.unlock()
        browser.start(queue: queue)
    }

    public func join(_ candidate: PairingCandidate, localDevice: DeviceDescriptor) throws {
        lock.lock()
        guard !isHost else { lock.unlock(); throw PairingServiceError.notReady }
        let crypto = PairingCryptoSession()
        self.crypto = crypto
        self.peerOffer = candidate.offer
        self.localDevice = localDevice
        let connection = NWConnection(to: candidate.endpoint, using: .tcp)
        let channel = PairingChannel(connection: connection)
        self.channel = channel
        lock.unlock()

        let code = try crypto.shortAuthenticationCode(peerOffer: candidate.offer)
        promptHandler?(PairingPrompt(peer: DeviceDescriptor(id: candidate.id, name: candidate.name), code: code))
        channel.messageHandler = { [weak self] message in self?.handle(message) }
        channel.stateHandler = { [weak self] state in
            if case let .failed(error) = state { self?.fail(error.localizedDescription) }
        }
        connection.start(queue: queue)
        channel.send(.join(device: localDevice, offer: crypto.offer))
    }

    public func confirm() {
        lock.lock()
        localConfirmed = true
        let channel = channel
        let host = isHost
        lock.unlock()
        channel?.send(.confirmation)
        if host { completeHostIfReady() }
    }

    public func reject() {
        lock.lock()
        let channel = channel
        lock.unlock()
        channel?.send(.reject)
        stop()
    }

    public func stop() {
        lock.lock()
        let listener = listener
        let browser = browser
        let channel = channel
        self.listener = nil
        self.browser = nil
        self.channel = nil
        crypto = nil
        workspace = nil
        workspaceKey = nil
        localDevice = nil
        peerDevice = nil
        peerOffer = nil
        localConfirmed = false
        peerConfirmed = false
        isHost = false
        lock.unlock()
        listener?.cancel()
        browser?.cancel()
        channel?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        guard isHost, channel == nil else {
            lock.unlock()
            connection.cancel()
            return
        }
        let channel = PairingChannel(connection: connection)
        self.channel = channel
        lock.unlock()
        channel.messageHandler = { [weak self] message in self?.handle(message) }
        channel.stateHandler = { [weak self] state in
            if case let .failed(error) = state { self?.fail(error.localizedDescription) }
        }
        connection.start(queue: queue)
    }

    private func handleCandidates(_ results: Set<NWBrowser.Result>) {
        let candidates = results.compactMap { result -> PairingCandidate? in
            guard case let .bonjour(record) = result.metadata,
                  let deviceString = record["device"], let uuid = UUID(uuidString: deviceString),
                  let publicString = record["publicKey"], let publicKey = Data(base64Encoded: publicString),
                  let nonceString = record["nonce"], let nonce = Data(base64Encoded: nonceString) else { return nil }
            return PairingCandidate(
                id: DeviceID(rawValue: uuid),
                name: record["name"] ?? "Mac",
                endpoint: result.endpoint,
                offer: PairingOffer(publicKey: publicKey, nonce: nonce)
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        candidatesHandler?(candidates)
    }

    private func handle(_ message: PairingMessage) {
        switch message {
        case let .join(device, offer):
            lock.lock()
            guard isHost, let crypto else { lock.unlock(); fail(PairingServiceError.notReady.localizedDescription); return }
            peerDevice = device
            peerOffer = offer
            lock.unlock()
            do {
                let code = try crypto.shortAuthenticationCode(peerOffer: offer)
                promptHandler?(PairingPrompt(peer: device, code: code))
            } catch {
                fail(error.localizedDescription)
            }
        case .confirmation:
            lock.lock()
            peerConfirmed = true
            let host = isHost
            lock.unlock()
            if host { completeHostIfReady() }
        case let .credential(snapshot, sealed):
            lock.lock()
            guard !isHost, localConfirmed, peerConfirmed, let crypto, let offer = peerOffer, let localDevice else {
                lock.unlock()
                fail(PairingServiceError.notReady.localizedDescription)
                return
            }
            lock.unlock()
            do {
                let key = try crypto.openWorkspaceKey(sealed, peerOffer: offer)
                var localSnapshot = snapshot
                localSnapshot.localDeviceID = localDevice.id
                joinedHandler?(localSnapshot, key)
                stop()
            } catch {
                fail(error.localizedDescription)
            }
        case .reject:
            fail(PairingServiceError.peerRejected.localizedDescription)
            stop()
        }
    }

    private func completeHostIfReady() {
        lock.lock()
        guard isHost, localConfirmed, peerConfirmed,
              let crypto, let offer = peerOffer, let key = workspaceKey,
              var snapshot = workspace, let peerDevice, let channel else {
            lock.unlock()
            return
        }
        if let index = snapshot.devices.firstIndex(where: { $0.id == peerDevice.id }) {
            snapshot.devices[index] = peerDevice
        } else {
            snapshot.devices.append(peerDevice)
        }
        workspace = snapshot
        let finalSnapshot = snapshot
        lock.unlock()
        do {
            let sealed = try crypto.sealWorkspaceKey(key, peerOffer: offer)
            channel.send(.credential(workspace: finalSnapshot, sealed: sealed)) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.fail(error.localizedDescription)
                } else {
                    self.hostUpdatedHandler?(finalSnapshot)
                    self.stop()
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        failureHandler?(message)
    }
}

private enum PairingMessage: Codable, Sendable {
    case join(device: DeviceDescriptor, offer: PairingOffer)
    case confirmation
    case credential(workspace: WorkspaceSnapshot, sealed: SealedWorkspaceCredential)
    case reject
}

private final class PairingChannel: @unchecked Sendable {
    let connection: NWConnection
    var messageHandler: (@Sendable (PairingMessage) -> Void)?
    var stateHandler: (@Sendable (NWConnection.State) -> Void)?
    private let lock = NSLock()
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateHandler?(state)
            if case .ready = state { self?.receiveNext() }
        }
    }

    func send(_ message: PairingMessage, completion: (@Sendable (NWError?) -> Void)? = nil) {
        guard let payload = try? JSONEncoder().encode(message), payload.count <= 65_536 else {
            completion?(NWError.posix(.EINVAL))
            return
        }
        var data = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        connection.send(content: data, completion: .contentProcessed { error in completion?(error) })
    }

    func cancel() { connection.cancel() }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_540) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if !complete, error == nil { self.receiveNext() }
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var messages: [Data] = []
        while buffer.count >= 4 {
            let size = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard size <= 65_536 else { buffer.removeAll(); lock.unlock(); cancel(); return }
            guard buffer.count >= size + 4 else { break }
            messages.append(Data(buffer.dropFirst(4).prefix(size)))
            buffer.removeFirst(size + 4)
        }
        lock.unlock()
        for data in messages {
            guard let message = try? JSONDecoder().decode(PairingMessage.self, from: data) else { cancel(); return }
            messageHandler?(message)
        }
    }
}
