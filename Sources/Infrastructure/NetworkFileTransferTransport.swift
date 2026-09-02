import CryptoKit
import Foundation
import Network
import UniSpaceApplication
import UniSpaceDomain

public enum NetworkFileTransferError: Error, Equatable, Sendable {
    case notStarted
    case peerUnavailable(DeviceID)
    case invalidConfiguration
    case authenticationFailed
    case replayedFrame
    case malformedPacket
    case sendFailed(String)
}

public final class NetworkFileTransferTransport: FileTransferTransport, @unchecked Sendable {
    public static let serviceType = "_unispace-xfer._tcp"
    public static let contentPort = NWEndpoint.Port(rawValue: 61_340)!

    private let queue = DispatchQueue(label: "com.layatai.unispace.file-transfer", qos: .utility)
    private let lock = NSLock()
    private let configuredListenPort: NWEndpoint.Port
    private let configuredDirectPort: NWEndpoint.Port
    private let enableBonjour: Bool
    private let stream: AsyncStream<FileTransferTransportEvent>
    private let continuation: AsyncStream<FileTransferTransportEvent>.Continuation

    private var localDevice: DeviceDescriptor?
    private var workspaceID: WorkspaceID?
    private var workspaceKey: Data?
    private var knownPeers: [DeviceID: DeviceDescriptor] = [:]
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var readyPort: NWEndpoint.Port?
    private var connections: [DeviceID: SecureFileTransferConnection] = [:]
    private var pendingConnections: [ObjectIdentifier: SecureFileTransferConnection] = [:]
    private var retryAttempts: [DeviceID: Int] = [:]
    private var retryTokens: [DeviceID: UUID] = [:]
    private var desiredPeerID: DeviceID?
    private var running = false

    public init(
        listenPort: NWEndpoint.Port = NetworkFileTransferTransport.contentPort,
        directPort: NWEndpoint.Port = NetworkFileTransferTransport.contentPort,
        enableBonjour: Bool = true
    ) {
        configuredListenPort = listenPort
        configuredDirectPort = directPort
        self.enableBonjour = enableBonjour
        var captured: AsyncStream<FileTransferTransportEvent>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    deinit {
        continuation.finish()
    }

    public func events() -> AsyncStream<FileTransferTransportEvent> { stream }

    public var activePort: NWEndpoint.Port? {
        lock.transferWithLock { readyPort }
    }

    public func start(
        localDevice: DeviceDescriptor,
        workspace: WorkspaceSnapshot,
        key: Data
    ) async throws {
        guard key.count >= 32,
              workspace.localDeviceID == localDevice.id,
              workspace.devices.contains(where: { $0.id == localDevice.id }) else {
            throw NetworkFileTransferError.invalidConfiguration
        }
        stopSynchronously()
        lock.transferWithLock {
            self.localDevice = localDevice
            workspaceID = workspace.id
            workspaceKey = key
            knownPeers = Dictionary(uniqueKeysWithValues: workspace.devices
                .filter { $0.id != localDevice.id }
                .map { ($0.id, $0) })
            running = true
        }

        let parameters = Self.makeParameters()
        let listener = try NWListener(using: parameters, on: configuredListenPort)
        if enableBonjour {
            let record = NWTXTRecord([
                "device": localDevice.id.rawValue.uuidString,
                "workspace": workspace.id.rawValue.uuidString,
                "version": String(FileTransferEnvelope.protocolVersion)
            ])
            listener.service = NWListener.Service(
                name: localDevice.name,
                type: Self.serviceType,
                txtRecord: record
            )
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            self?.handleListenerState(state, listener: listener)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        let browser: NWBrowser?
        if enableBonjour {
            let activeBrowser = NWBrowser(
                for: .bonjour(type: Self.serviceType, domain: nil),
                using: parameters
            )
            activeBrowser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .waiting:
                    self?.emit(.failure(nil, .contentChannelUnavailable))
                default:
                    break
                }
            }
            activeBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.handle(results)
            }
            activeBrowser.start(queue: queue)
            browser = activeBrowser
        } else {
            browser = nil
        }

        lock.transferWithLock {
            self.listener = listener
            self.browser = browser
        }

    }

    public func stop() async {
        stopSynchronously()
    }

    public func setDesiredPeer(_ deviceID: DeviceID?) {
        queue.async { [weak self] in
            guard let self else { return }
            let cancelled = self.lock.transferWithLock { () -> [SecureFileTransferConnection] in
                self.desiredPeerID = deviceID
                let staleRetryIDs = self.retryTokens.keys.filter { $0 != deviceID }
                for id in staleRetryIDs {
                    self.retryTokens.removeValue(forKey: id)
                    self.retryAttempts.removeValue(forKey: id)
                }
                let stale = self.pendingConnections.filter {
                    $0.value.isOutbound && $0.value.expectedDeviceID != deviceID
                }
                for (objectID, _) in stale { self.pendingConnections.removeValue(forKey: objectID) }
                return stale.map(\.value)
            }
            cancelled.forEach { $0.cancel() }
            let shouldDial = deviceID.map { peerID in
                self.lock.transferWithLock { PeerConnectionPolicy.macCanDial(self.knownPeers[peerID]) }
            } ?? false
            if shouldDial, let deviceID { self.scheduleDirectConnection(to: deviceID, immediately: true) }
        }
    }

    public func send(_ envelope: FileTransferEnvelope, to deviceID: DeviceID) async throws {
        guard let connection = lock.transferWithLock({ connections[deviceID] }) else {
            throw NetworkFileTransferError.peerUnavailable(deviceID)
        }
        try await connection.send(FileTransferFrameCodec.encode(envelope))
    }

    private func stopSynchronously() {
        let values: (NWListener?, NWBrowser?, [SecureFileTransferConnection]) = lock.transferWithLock {
            let values = (
                listener,
                browser,
                Array(connections.values) + Array(pendingConnections.values)
            )
            listener = nil
            browser = nil
            readyPort = nil
            connections.removeAll()
            pendingConnections.removeAll()
            retryAttempts.removeAll()
            retryTokens.removeAll()
            desiredPeerID = nil
            knownPeers.removeAll()
            localDevice = nil
            workspaceID = nil
            workspaceKey = nil
            running = false
            return values
        }
        values.0?.cancel()
        values.1?.cancel()
        values.2.forEach { $0.cancel() }
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener?) {
        switch state {
        case .ready:
            lock.transferWithLock { readyPort = listener?.port }
        case .failed, .waiting:
            emit(.failure(nil, .contentChannelUnavailable))
        default:
            break
        }
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        guard let configuration = lock.transferWithLock({ () -> (DeviceDescriptor, WorkspaceID)? in
            guard let localDevice, let workspaceID else { return nil }
            return (localDevice, workspaceID)
        }) else { return }

        var candidates: [(DeviceDescriptor, NWEndpoint)] = []
        for result in results {
            guard case let .bonjour(record) = result.metadata,
                  record["workspace"] == configuration.1.rawValue.uuidString,
                  record["version"] == String(FileTransferEnvelope.protocolVersion),
                  let deviceString = record["device"],
                  let uuid = UUID(uuidString: deviceString) else { continue }
            let deviceID = DeviceID(rawValue: uuid)
            guard deviceID != configuration.0.id,
                  deviceID == lock.transferWithLock({ desiredPeerID }) else { continue }

            let candidate = lock.transferWithLock { () -> DeviceDescriptor? in
                guard connections[deviceID] == nil,
                      !pendingConnections.values.contains(where: { $0.expectedDeviceID == deviceID }) else {
                    return nil
                }
                return knownPeers[deviceID]
            }
            if let candidate { candidates.append((candidate, result.endpoint)) }
        }
        for (peer, endpoint) in candidates {
            connect(to: endpoint, expectedDevice: peer, isOutbound: true)
        }
    }

    private func accept(_ connection: NWConnection) {
        install(connection, expectedDeviceID: nil, isOutbound: false)
        connection.start(queue: queue)
    }

    private func connect(
        to endpoint: NWEndpoint,
        expectedDevice: DeviceDescriptor,
        isOutbound: Bool
    ) {
        let connection = NWConnection(to: endpoint, using: Self.makeParameters())
        install(connection, expectedDeviceID: expectedDevice.id, isOutbound: isOutbound)
        connection.start(queue: queue)
    }

    private func install(
        _ connection: NWConnection,
        expectedDeviceID: DeviceID?,
        isOutbound: Bool
    ) {
        guard let configuration = lock.transferWithLock({ () -> (DeviceID, WorkspaceID, Data)? in
            guard let localDevice, let workspaceID, let workspaceKey else { return nil }
            return (localDevice.id, workspaceID, workspaceKey)
        }) else {
            connection.cancel()
            return
        }

        let secure = SecureFileTransferConnection(
            connection: connection,
            localDeviceID: configuration.0,
            workspaceID: configuration.1,
            workspaceKey: configuration.2,
            expectedDeviceID: expectedDeviceID,
            isOutbound: isOutbound
        )
        let objectID = ObjectIdentifier(secure)
        lock.transferWithLock { pendingConnections[objectID] = secure }

        secure.stateHandler = { [weak self, weak secure] state in
            guard let self, let secure else { return }
            self.handleConnectionState(
                state,
                secure: secure,
                objectID: objectID,
                expectedDeviceID: expectedDeviceID
            )
        }
        secure.authenticatedHandler = { [weak self, weak secure] deviceID in
            guard let self, let secure else { return }
            self.register(secure, as: deviceID, objectID: objectID)
        }
        secure.frameHandler = { [weak self, weak secure] data in
            guard let self, let secure, let deviceID = secure.deviceID else { return }
            do {
                let envelope = try FileTransferFrameCodec.decode(data)
                guard envelope.senderDeviceID == deviceID else {
                    throw NetworkFileTransferError.authenticationFailed
                }
                self.emit(.message(deviceID, envelope))
            } catch {
                self.emit(.failure(deviceID, .protocolViolation))
                secure.cancel()
            }
        }
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        secure: SecureFileTransferConnection,
        objectID: ObjectIdentifier,
        expectedDeviceID: DeviceID?
    ) {
        switch state {
        case .failed, .cancelled:
            remove(secure, objectID: objectID, expectedDeviceID: expectedDeviceID)
        case .waiting:
            emit(.failure(expectedDeviceID, .contentChannelUnavailable))
        default:
            break
        }
    }

    private func register(
        _ secure: SecureFileTransferConnection,
        as deviceID: DeviceID,
        objectID: ObjectIdentifier
    ) {
        let localID = lock.transferWithLock { localDevice?.id }
        var replaced: SecureFileTransferConnection?
        var rejected = false
        var newlyConnected = false
        lock.transferWithLock {
            pendingConnections.removeValue(forKey: objectID)
            if let existing = connections[deviceID], existing !== secure {
                let prefersOutbound = localID.map { $0 < deviceID } ?? false
                let newPreferred = secure.isOutbound == prefersOutbound
                let existingPreferred = existing.isOutbound == prefersOutbound
                if newPreferred && !existingPreferred {
                    connections[deviceID] = secure
                    replaced = existing
                } else {
                    rejected = true
                }
            } else {
                newlyConnected = connections[deviceID] == nil
                connections[deviceID] = secure
            }
            retryTokens.removeValue(forKey: deviceID)
        }

        if rejected {
            secure.cancel()
            return
        }
        replaced?.cancel()
        if newlyConnected { emit(.connected(deviceID)) }
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak secure] in
            guard let self, let secure else { return }
            self.lock.transferWithLock {
                guard self.connections[deviceID] === secure else { return }
                self.retryAttempts[deviceID] = 0
            }
        }
    }

    private func remove(
        _ secure: SecureFileTransferConnection,
        objectID: ObjectIdentifier,
        expectedDeviceID: DeviceID?
    ) {
        let removedDeviceID: DeviceID? = lock.transferWithLock {
            pendingConnections.removeValue(forKey: objectID)
            guard let deviceID = secure.deviceID, connections[deviceID] === secure else {
                return nil
            }
            connections.removeValue(forKey: deviceID)
            return deviceID
        }

        if let removedDeviceID {
            emit(.disconnected(removedDeviceID))
            scheduleDirectConnection(to: removedDeviceID, immediately: false)
        } else if let expectedDeviceID {
            scheduleDirectConnection(to: expectedDeviceID, immediately: false)
        }
    }

    private func scheduleDirectConnection(to deviceID: DeviceID, immediately: Bool) {
        let schedule: (UUID, TimeInterval)? = lock.transferWithLock {
            guard running,
                  desiredPeerID == deviceID,
                  PeerConnectionPolicy.macCanDial(knownPeers[deviceID]),
                  connections[deviceID] == nil,
                  retryTokens[deviceID] == nil,
                  let peer = knownPeers[deviceID],
                  !peer.peerAddresses.isEmpty else { return nil }
            let attempt = retryAttempts[deviceID, default: 0]
            let delay = immediately ? 0 : ConnectionRetrySchedule.delay(forAttempt: max(attempt - 1, 0))
            let token = UUID()
            retryTokens[deviceID] = token
            return (token, delay)
        }
        guard let (token, delay) = schedule else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attemptDirectConnection(to: deviceID, token: token)
        }
    }

    private func attemptDirectConnection(to deviceID: DeviceID, token: UUID) {
        let target: (DeviceDescriptor, PeerAddress)? = lock.transferWithLock {
            guard running,
                  retryTokens[deviceID] == token,
                  connections[deviceID] == nil,
                  !pendingConnections.values.contains(where: { $0.expectedDeviceID == deviceID }),
                  let peer = knownPeers[deviceID],
                  !peer.peerAddresses.isEmpty else {
                retryTokens.removeValue(forKey: deviceID)
                return nil
            }
            retryTokens.removeValue(forKey: deviceID)
            let attempt = retryAttempts[deviceID, default: 0]
            retryAttempts[deviceID] = attempt + 1
            return (peer, peer.peerAddresses[attempt % peer.peerAddresses.count])
        }
        guard let (peer, address) = target else { return }
        connect(
            to: .hostPort(
                host: NWEndpoint.Host(address.host),
                port: configuredDirectPort
            ),
            expectedDevice: peer,
            isOutbound: true
        )
    }

    private func emit(_ event: FileTransferTransportEvent) {
        continuation.yield(event)
    }

    static func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = false
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .background
        return parameters
    }
}

private enum FileTransferPacketKind: UInt8 {
    case hello = 1
    case sealed = 2
}

struct FileTransferChannelHello: Codable, Sendable {
    let version: UInt16
    let workspaceID: WorkspaceID
    let deviceID: DeviceID
    let nonce: Data
    let proof: Data

    private enum CodingKeys: String, CodingKey {
        case version
        case workspaceID
        case deviceID
        case nonce
        case proof
    }

    init(
        version: UInt16,
        workspaceID: WorkspaceID,
        deviceID: DeviceID,
        nonce: Data,
        proof: Data
    ) {
        self.version = version
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.nonce = nonce
        self.proof = proof
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt16.self, forKey: .version)
        workspaceID = try container.decodeUUIDIdentifier(WorkspaceID.self, forKey: .workspaceID)
        deviceID = try container.decodeUUIDIdentifier(DeviceID.self, forKey: .deviceID)
        nonce = try container.decode(Data.self, forKey: .nonce)
        proof = try container.decode(Data.self, forKey: .proof)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeUUIDIdentifier(workspaceID, forKey: .workspaceID)
        try container.encodeUUIDIdentifier(deviceID, forKey: .deviceID)
        try container.encode(nonce, forKey: .nonce)
        try container.encode(proof, forKey: .proof)
    }
}

final class SecureFileTransferConnection: @unchecked Sendable {
    let connection: NWConnection
    let expectedDeviceID: DeviceID?
    let isOutbound: Bool
    var stateHandler: (@Sendable (NWConnection.State) -> Void)?
    var authenticatedHandler: (@Sendable (DeviceID) -> Void)?
    var frameHandler: (@Sendable (Data) -> Void)?

    private let localDeviceID: DeviceID
    private let workspaceID: WorkspaceID
    private let workspaceKey: SymmetricKey
    private let localNonce: Data
    private let lock = NSLock()
    private var buffer = Data()
    private var sessionKey: SymmetricKey?
    private var authenticatedDeviceID: DeviceID?
    private var outboundSequence: UInt64 = 0
    private var inboundSequence: UInt64?

    var deviceID: DeviceID? {
        lock.transferWithLock { authenticatedDeviceID }
    }

    init(
        connection: NWConnection,
        localDeviceID: DeviceID,
        workspaceID: WorkspaceID,
        workspaceKey: Data,
        expectedDeviceID: DeviceID?,
        isOutbound: Bool
    ) {
        self.connection = connection
        self.localDeviceID = localDeviceID
        self.workspaceID = workspaceID
        self.workspaceKey = SymmetricKey(data: workspaceKey)
        self.expectedDeviceID = expectedDeviceID
        self.isOutbound = isOutbound
        localNonce = PairingCryptoSession.randomData(count: 32)
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateHandler?(state)
            if case .ready = state {
                self?.receiveNext()
                self?.sendHello()
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            send(data) { error in
                if let error {
                    continuation.resume(
                        throwing: NetworkFileTransferError.sendFailed(error.localizedDescription)
                    )
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func send(_ data: Data, completion: (@Sendable (NWError?) -> Void)?) {
        do {
            let packet = try seal(data)
            connection.send(
                content: packet,
                completion: .contentProcessed { error in completion?(error) }
            )
        } catch {
            completion?(NWError.posix(.EAUTH))
            cancel()
        }
    }

    private func sendHello() {
        let payload = helloProofPayload(deviceID: localDeviceID, nonce: localNonce)
        let proof = Data(HMAC<SHA256>.authenticationCode(for: payload, using: workspaceKey))
        let hello = FileTransferChannelHello(
            version: FileTransferEnvelope.protocolVersion,
            workspaceID: workspaceID,
            deviceID: localDeviceID,
            nonce: localNonce,
            proof: proof
        )
        guard let encoded = try? JSONEncoder().encode(hello) else {
            cancel()
            return
        }
        connection.send(
            content: Self.outerFrame(kind: .hello, payload: encoded),
            completion: .contentProcessed { [weak self] error in
                if error != nil { self?.cancel() }
            }
        )
    }

    private func handleHello(_ payload: Data) throws {
        let hello = try JSONDecoder().decode(FileTransferChannelHello.self, from: payload)
        guard hello.version == FileTransferEnvelope.protocolVersion,
              hello.workspaceID == workspaceID,
              hello.deviceID != localDeviceID,
              expectedDeviceID == nil || expectedDeviceID == hello.deviceID else {
            throw NetworkFileTransferError.authenticationFailed
        }
        let proofPayload = helloProofPayload(deviceID: hello.deviceID, nonce: hello.nonce)
        guard HMAC<SHA256>.isValidAuthenticationCode(
            hello.proof,
            authenticating: proofPayload,
            using: workspaceKey
        ) else {
            throw NetworkFileTransferError.authenticationFailed
        }

        let localFirst = localDeviceID < hello.deviceID
        let salt = localFirst ? localNonce + hello.nonce : hello.nonce + localNonce
        let info = Data(
            "UniSpace content channel v1|\(workspaceID.rawValue.uuidString)".utf8
        )
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: workspaceKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        let shouldNotify = lock.transferWithLock { () -> Bool in
            guard sessionKey == nil else { return false }
            sessionKey = derived
            authenticatedDeviceID = hello.deviceID
            return true
        }
        if shouldNotify { authenticatedHandler?(hello.deviceID) }
    }

    private func seal(_ data: Data) throws -> Data {
        let values = try lock.transferWithLock { () throws -> (SymmetricKey, UInt64) in
            guard let sessionKey else { throw NetworkFileTransferError.authenticationFailed }
            let sequence = outboundSequence
            outboundSequence &+= 1
            return (sessionKey, sequence)
        }
        var plaintext = Data()
        var sequence = values.1.bigEndian
        withUnsafeBytes(of: &sequence) { plaintext.append(contentsOf: $0) }
        plaintext.append(data)
        let sealed = try ChaChaPoly.seal(plaintext, using: values.0)
        return Self.outerFrame(kind: .sealed, payload: sealed.combined)
    }

    private func open(_ payload: Data) throws -> Data {
        let key = try lock.transferWithLock { () throws -> SymmetricKey in
            guard let sessionKey else { throw NetworkFileTransferError.authenticationFailed }
            return sessionKey
        }
        let box = try ChaChaPoly.SealedBox(combined: payload)
        let plaintext = try ChaChaPoly.open(box, using: key)
        guard plaintext.count >= 8 else { throw NetworkFileTransferError.malformedPacket }
        let sequence = plaintext.prefix(8).reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        try lock.transferWithLock {
            if let inboundSequence, sequence <= inboundSequence {
                throw NetworkFileTransferError.replayedFrame
            }
            inboundSequence = sequence
        }
        return Data(plaintext.dropFirst(8))
    }

    private func helloProofPayload(deviceID: DeviceID, nonce: Data) -> Data {
        var data = Data("UniSpace secure content hello v1".utf8)
        data.append(Data(workspaceID.rawValue.uuidString.utf8))
        data.append(Data(deviceID.rawValue.uuidString.utf8))
        data.append(nonce)
        return data
    }

    private func receiveNext() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if error == nil, !complete {
                self.receiveNext()
            } else {
                self.cancel()
            }
        }
    }

    private func consume(_ data: Data) {
        let packets: [(FileTransferPacketKind, Data)]? = lock.transferWithLock {
            buffer.append(data)
            var packets: [(FileTransferPacketKind, Data)] = []
            while buffer.count >= 5 {
                let length = Int(buffer.prefix(4).reduce(UInt32(0)) {
                    ($0 << 8) | UInt32($1)
                })
                let kindIndex = buffer.index(buffer.startIndex, offsetBy: 4)
                guard length <= FileTransferFrameCodec.maximumEncodedSize + 64,
                      let kind = FileTransferPacketKind(rawValue: buffer[kindIndex]) else {
                    buffer.removeAll()
                    return nil
                }
                guard buffer.count >= length + 5 else { break }
                packets.append((kind, Data(buffer.dropFirst(5).prefix(length))))
                buffer.removeFirst(length + 5)
            }
            return packets
        }
        guard let packets else {
            cancel()
            return
        }

        do {
            for (kind, payload) in packets {
                switch kind {
                case .hello:
                    try handleHello(payload)
                case .sealed:
                    frameHandler?(try open(payload))
                }
            }
        } catch {
            cancel()
        }
    }

    private static func outerFrame(
        kind: FileTransferPacketKind,
        payload: Data
    ) -> Data {
        var result = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(kind.rawValue)
        result.append(payload)
        return result
    }
}

private extension NSLock {
    @inline(__always)
    func transferWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
