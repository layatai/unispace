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
        case .peerRejected: "The other device rejected pairing."
        case .workspaceFull: "A UniSpace workspace supports up to four devices."
        case let .network(message): message
        }
    }
}

public enum PairingNetworkStatus: Equatable, Sendable {
    case ready
    case waiting(String)
    case failed(String)
}

public final class PairingNetworkService: @unchecked Sendable {
    public static let serviceType = "_unispace-pair._tcp"
    public static let directPort = NWEndpoint.Port(rawValue: 61_337)!

    public var candidatesHandler: (@Sendable ([PairingCandidate]) -> Void)?
    public var promptHandler: (@Sendable (PairingPrompt) -> Void)?
    public var joinedHandler: (@Sendable (WorkspaceSnapshot, Data) -> Void)?
    public var hostUpdatedHandler: (@Sendable (WorkspaceSnapshot) -> Void)?
    public var failureHandler: (@Sendable (String) -> Void)?
    public var statusHandler: (@Sendable (PairingNetworkStatus) -> Void)?

    private let queue = DispatchQueue(label: "com.layatai.unispace.pairing", qos: .userInitiated)
    private let lock = NSLock()
    private let configuredListenPort: NWEndpoint.Port
    private let configuredDirectPort: NWEndpoint.Port
    private var listener: NWListener?
    private var directListener: NWListener?
    private var directReadyPort: NWEndpoint.Port?
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
    private var directHostAddress: PeerAddress?
    private var acceptedPeerAddress: PeerAddress?

    public init(
        listenPort: NWEndpoint.Port = PairingNetworkService.directPort,
        directPort: NWEndpoint.Port = PairingNetworkService.directPort
    ) {
        configuredListenPort = listenPort
        configuredDirectPort = directPort
    }

    public var activeDirectPort: NWEndpoint.Port? {
        lock.withLock { directReadyPort }
    }

    public func startHosting(workspace: WorkspaceSnapshot, key: Data, localDevice: DeviceDescriptor) throws {
        guard workspace.devices.count < 4 else { throw PairingServiceError.workspaceFull }
        stop()
        let crypto = PairingCryptoSession()
        let listener = try NWListener(using: .tcp, on: .any)
        let directListener = try NWListener(using: .tcp, on: configuredListenPort)
        let record = NWTXTRecord([
            "device": localDevice.id.rawValue.uuidString,
            "name": localDevice.name,
            "publicKey": crypto.offer.publicKey.base64EncodedString(),
            "nonce": crypto.offer.nonce.base64EncodedString(),
            "version": "1"
        ])
        listener.service = NWListener.Service(name: localDevice.name, type: Self.serviceType, txtRecord: record)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, sendsOffer: false) }
        listener.stateUpdateHandler = { [weak self] state in self?.handleListenerState(state) }
        directListener.newConnectionHandler = { [weak self] connection in self?.accept(connection, sendsOffer: true) }
        directListener.stateUpdateHandler = { [weak self, weak directListener] state in
            self?.handleDirectListenerState(state, listener: directListener)
        }
        lock.lock()
        self.crypto = crypto
        self.listener = listener
        self.directListener = directListener
        self.workspace = workspace
        self.workspaceKey = key
        self.localDevice = localDevice
        self.isHost = true
        lock.unlock()
        listener.start(queue: queue)
        directListener.start(queue: queue)
    }

    public func startBrowsing() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.handleCandidates(results) }
        browser.stateUpdateHandler = { [weak self] state in self?.handleBrowserState(state) }
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

    public func join(_ address: PeerAddress, localDevice: DeviceDescriptor) throws {
        lock.lock()
        guard !isHost, channel == nil else { lock.unlock(); throw PairingServiceError.notReady }
        let crypto = PairingCryptoSession()
        self.crypto = crypto
        self.localDevice = localDevice
        directHostAddress = address
        let connection = NWConnection(
            host: NWEndpoint.Host(address.host),
            port: configuredDirectPort,
            using: .tcp
        )
        let channel = PairingChannel(connection: connection)
        self.channel = channel
        lock.unlock()

        channel.messageHandler = { [weak self] message in self?.handle(message) }
        channel.stateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.statusHandler?(.waiting("Connected. Waiting for the pairing code."))
            case let .failed(error):
                self?.fail("Could not connect to \(address.host): \(error.localizedDescription)")
            default:
                break
            }
        }
        statusHandler?(.waiting("Connecting to \(address.host) through Tailscale"))
        connection.start(queue: queue)
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
        let directListener = directListener
        let browser = browser
        let channel = channel
        self.listener = nil
        self.directListener = nil
        directReadyPort = nil
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
        directHostAddress = nil
        acceptedPeerAddress = nil
        lock.unlock()
        listener?.cancel()
        directListener?.cancel()
        browser?.cancel()
        channel?.cancel()
    }

    private func accept(_ connection: NWConnection, sendsOffer: Bool) {
        lock.lock()
        guard isHost, channel == nil, let localDevice, let crypto else {
            lock.unlock()
            connection.cancel()
            return
        }
        let channel = PairingChannel(connection: connection)
        self.channel = channel
        acceptedPeerAddress = sendsOffer ? Self.peerAddress(from: connection.endpoint) : nil
        lock.unlock()
        channel.messageHandler = { [weak self] message in self?.handle(message) }
        channel.stateHandler = { [weak self, weak channel] state in
            switch state {
            case .ready where sendsOffer:
                channel?.send(.offer(device: localDevice, offer: crypto.offer))
            case .cancelled:
                // A stray or dropped connection (port probes included) must not
                // wedge the host: the next joiner needs the empty-channel slot.
                self?.clearChannel(channel)
            case let .failed(error):
                self?.clearChannel(channel)
                self?.fail(error.localizedDescription)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func clearChannel(_ channel: PairingChannel?) {
        lock.lock()
        if channel === self.channel || channel == nil { self.channel = nil }
        lock.unlock()
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
        case let .offer(device, offer):
            lock.lock()
            guard !isHost, let crypto, let localDevice, let channel else {
                lock.unlock()
                fail(PairingServiceError.notReady.localizedDescription)
                return
            }
            var hostDevice = device
            if let directHostAddress, !hostDevice.peerAddresses.contains(directHostAddress) {
                hostDevice.peerAddresses.append(directHostAddress)
            }
            peerDevice = hostDevice
            peerOffer = offer
            lock.unlock()
            do {
                let code = try crypto.shortAuthenticationCode(peerOffer: offer)
                promptHandler?(PairingPrompt(peer: hostDevice, code: code))
                channel.send(.join(device: localDevice, offer: crypto.offer))
            } catch {
                fail(error.localizedDescription)
            }
        case let .join(device, offer):
            lock.lock()
            guard isHost, let crypto else { lock.unlock(); fail(PairingServiceError.notReady.localizedDescription); return }
            var routedDevice = device
            if let acceptedPeerAddress, !routedDevice.peerAddresses.contains(acceptedPeerAddress) {
                routedDevice.peerAddresses.append(acceptedPeerAddress)
            }
            peerDevice = routedDevice
            peerOffer = offer
            lock.unlock()
            do {
                let code = try crypto.shortAuthenticationCode(peerOffer: offer)
                promptHandler?(PairingPrompt(peer: routedDevice, code: code))
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
                if let peerDevice,
                   let index = localSnapshot.devices.firstIndex(where: { $0.id == peerDevice.id }) {
                    localSnapshot.devices[index] = Self.merging(localSnapshot.devices[index], with: peerDevice)
                }
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

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            statusHandler?(.ready)
        case let .waiting(error):
            statusHandler?(.waiting(error.localizedDescription))
        case let .failed(error):
            statusHandler?(.failed(error.localizedDescription))
        default:
            break
        }
    }

    private func handleDirectListenerState(_ state: NWListener.State, listener: NWListener?) {
        if case .ready = state, let port = listener?.port {
            lock.withLock { directReadyPort = port }
        }
        handleListenerState(state)
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            statusHandler?(.ready)
        case let .waiting(error):
            statusHandler?(.waiting(error.localizedDescription))
        case let .failed(error):
            statusHandler?(.failed(error.localizedDescription))
        default:
            break
        }
    }

    private static func peerAddress(from endpoint: NWEndpoint) -> PeerAddress? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        return try? PeerAddress(String(describing: host))
    }

    private static func merging(_ current: DeviceDescriptor, with incoming: DeviceDescriptor) -> DeviceDescriptor {
        var merged = incoming
        if merged.displays.isEmpty { merged.displays = current.displays }
        merged.peerAddresses = Array(Set(current.peerAddresses + incoming.peerAddresses))
            .sorted { $0.host < $1.host }
        return merged
    }
}

private enum PairingMessage: Codable, Sendable {
    case offer(device: DeviceDescriptor, offer: PairingOffer)
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
