import CryptoKit
import Foundation
import Network
import UniSpaceApplication
import UniSpaceDomain

public enum NetworkClipboardError: Error, Equatable, Sendable {
    case peerUnavailable(DeviceID)
    case invalidConfiguration
    case authenticationFailed
    case replayedFrame
    case malformedPacket
    case sendFailed(String)
}

/// A dedicated low-volume encrypted channel for active-peer text and URL
/// clipboard updates. It deliberately does not share the latency-sensitive
/// keyboard/pointer queues or the bulk file-transfer scheduler.
public final class NetworkClipboardTransport: ClipboardTransport, @unchecked Sendable {
    public static let serviceType = "_unispace-clip._tcp"
    public static let clipboardPort = NWEndpoint.Port(rawValue: 61_342)!

    private let queue = DispatchQueue(label: "com.layatai.unispace.clipboard", qos: .utility)
    private let lock = NSLock()
    private let configuredListenPort: NWEndpoint.Port
    private let configuredDirectPort: NWEndpoint.Port
    private let enableBonjour: Bool
    private let stream: AsyncStream<ClipboardTransportEvent>
    private let continuation: AsyncStream<ClipboardTransportEvent>.Continuation

    private var localDevice: DeviceDescriptor?
    private var workspaceID: WorkspaceID?
    private var workspaceKey: Data?
    private var knownPeers: [DeviceID: DeviceDescriptor] = [:]
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var readyPort: NWEndpoint.Port?
    private var connections: [DeviceID: SecureClipboardConnection] = [:]
    private var pendingConnections: [ObjectIdentifier: SecureClipboardConnection] = [:]
    private var retryAttempts: [DeviceID: Int] = [:]
    private var retryTokens: [DeviceID: UUID] = [:]
    private var running = false

    public init(
        listenPort: NWEndpoint.Port = NetworkClipboardTransport.clipboardPort,
        directPort: NWEndpoint.Port = NetworkClipboardTransport.clipboardPort,
        enableBonjour: Bool = true
    ) {
        configuredListenPort = listenPort
        configuredDirectPort = directPort
        self.enableBonjour = enableBonjour
        var captured: AsyncStream<ClipboardTransportEvent>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    deinit { continuation.finish() }

    public func events() -> AsyncStream<ClipboardTransportEvent> { stream }

    public var activePort: NWEndpoint.Port? {
        lock.clipboardWithLock { readyPort }
    }

    public func start(
        localDevice: DeviceDescriptor,
        workspace: WorkspaceSnapshot,
        key: Data
    ) async throws {
        guard key.count >= 32,
              workspace.localDeviceID == localDevice.id,
              workspace.devices.contains(where: { $0.id == localDevice.id }) else {
            throw NetworkClipboardError.invalidConfiguration
        }

        stopSynchronously()
        lock.clipboardWithLock {
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
            listener.service = NWListener.Service(
                name: localDevice.name,
                type: Self.serviceType,
                txtRecord: NWTXTRecord([
                    "device": localDevice.id.rawValue.uuidString,
                    "workspace": workspace.id.rawValue.uuidString,
                    "version": String(ClipboardEnvelope.protocolVersion)
                ])
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
            let value = NWBrowser(
                for: .bonjour(type: Self.serviceType, domain: nil),
                using: parameters
            )
            value.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .waiting:
                    self?.emit(.failure(nil))
                default:
                    break
                }
            }
            value.browseResultsChangedHandler = { [weak self] results, _ in
                self?.handle(results)
            }
            value.start(queue: queue)
            browser = value
        } else {
            browser = nil
        }

        lock.clipboardWithLock {
            self.listener = listener
            self.browser = browser
        }

        for peer in workspace.devices where peer.id != localDevice.id && !peer.peerAddresses.isEmpty {
            scheduleDirectConnection(to: peer.id, immediately: true)
        }
    }

    public func stop() async { stopSynchronously() }

    public func send(_ envelope: ClipboardEnvelope, to deviceID: DeviceID) async throws {
        guard let connection = lock.clipboardWithLock({ connections[deviceID] }) else {
            throw NetworkClipboardError.peerUnavailable(deviceID)
        }
        try await connection.send(ClipboardFrameCodec.encode(envelope))
    }

    private func stopSynchronously() {
        let values: (NWListener?, NWBrowser?, [SecureClipboardConnection]) = lock.clipboardWithLock {
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
            lock.clipboardWithLock { readyPort = listener?.port }
        case .failed:
            emit(.failure(nil))
        default:
            break
        }
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        guard let configuration = lock.clipboardWithLock({ () -> (DeviceDescriptor, WorkspaceID)? in
            guard let localDevice, let workspaceID else { return nil }
            return (localDevice, workspaceID)
        }) else { return }

        var candidates: [(DeviceDescriptor, NWEndpoint)] = []
        for result in results {
            guard case let .bonjour(record) = result.metadata,
                  record["workspace"] == configuration.1.rawValue.uuidString,
                  record["version"] == String(ClipboardEnvelope.protocolVersion),
                  let deviceString = record["device"],
                  let uuid = UUID(uuidString: deviceString) else { continue }
            let deviceID = DeviceID(rawValue: uuid)
            guard deviceID != configuration.0.id, configuration.0.id < deviceID else { continue }

            let peer = lock.clipboardWithLock { () -> DeviceDescriptor? in
                guard connections[deviceID] == nil,
                      !pendingConnections.values.contains(where: {
                          $0.expectedDeviceID == deviceID
                      }) else { return nil }
                return knownPeers[deviceID]
            }
            if let peer { candidates.append((peer, result.endpoint)) }
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
        guard let configuration = lock.clipboardWithLock({ () -> (DeviceID, WorkspaceID, Data)? in
            guard let localDevice, let workspaceID, let workspaceKey else { return nil }
            return (localDevice.id, workspaceID, workspaceKey)
        }) else {
            connection.cancel()
            return
        }

        let secure = SecureClipboardConnection(
            connection: connection,
            localDeviceID: configuration.0,
            workspaceID: configuration.1,
            workspaceKey: configuration.2,
            expectedDeviceID: expectedDeviceID,
            isOutbound: isOutbound
        )
        let objectID = ObjectIdentifier(secure)
        lock.clipboardWithLock { pendingConnections[objectID] = secure }

        secure.stateHandler = { [weak self, weak secure] state in
            guard let self, let secure else { return }
            switch state {
            case .failed, .cancelled:
                self.remove(secure, objectID: objectID, expectedDeviceID: expectedDeviceID)
            case .waiting:
                self.emit(.failure(expectedDeviceID))
            default:
                break
            }
        }
        secure.authenticatedHandler = { [weak self, weak secure] deviceID in
            guard let self, let secure else { return }
            self.register(secure, as: deviceID, objectID: objectID)
        }
        secure.frameHandler = { [weak self, weak secure] data in
            guard let self, let secure, let deviceID = secure.deviceID else { return }
            do {
                let envelope = try ClipboardFrameCodec.decode(data)
                guard envelope.senderDeviceID == deviceID else {
                    throw NetworkClipboardError.authenticationFailed
                }
                self.emit(.update(deviceID, envelope))
            } catch {
                self.emit(.failure(deviceID))
                secure.cancel()
            }
        }
    }

    private func register(
        _ secure: SecureClipboardConnection,
        as deviceID: DeviceID,
        objectID: ObjectIdentifier
    ) {
        let localID = lock.clipboardWithLock { localDevice?.id }
        var replaced: SecureClipboardConnection?
        var rejected = false
        var newlyConnected = false
        lock.clipboardWithLock {
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
            retryAttempts[deviceID] = 0
            retryTokens.removeValue(forKey: deviceID)
        }

        if rejected {
            secure.cancel()
            return
        }
        replaced?.cancel()
        if newlyConnected { emit(.connected(deviceID)) }
    }

    private func remove(
        _ secure: SecureClipboardConnection,
        objectID: ObjectIdentifier,
        expectedDeviceID: DeviceID?
    ) {
        let removedDeviceID: DeviceID? = lock.clipboardWithLock {
            pendingConnections.removeValue(forKey: objectID)
            guard let deviceID = secure.deviceID,
                  connections[deviceID] === secure else { return nil }
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
        let schedule: (UUID, TimeInterval)? = lock.clipboardWithLock {
            guard running,
                  connections[deviceID] == nil,
                  retryTokens[deviceID] == nil,
                  let peer = knownPeers[deviceID],
                  !peer.peerAddresses.isEmpty else { return nil }
            let attempt = retryAttempts[deviceID, default: 0]
            let delays: [TimeInterval] = [1, 2, 4, 8, 15]
            let delay = immediately ? 0 : delays[min(attempt, delays.count - 1)]
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
        let target: (DeviceDescriptor, PeerAddress)? = lock.clipboardWithLock {
            guard running,
                  retryTokens[deviceID] == token,
                  connections[deviceID] == nil,
                  !pendingConnections.values.contains(where: {
                      $0.expectedDeviceID == deviceID
                  }),
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

    private func emit(_ event: ClipboardTransportEvent) {
        continuation.yield(event)
    }

    static func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

private enum ClipboardPacketKind: UInt8 {
    case hello = 1
    case sealed = 2
}

private struct ClipboardChannelHello: Codable, Sendable {
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

final class SecureClipboardConnection: @unchecked Sendable {
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
        lock.clipboardWithLock { authenticatedDeviceID }
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
            do {
                let packet = try seal(data)
                connection.send(
                    content: packet,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(
                                throwing: NetworkClipboardError.sendFailed(
                                    error.localizedDescription
                                )
                            )
                        } else {
                            continuation.resume(returning: ())
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() { connection.cancel() }

    private func sendHello() {
        let payload = helloProofPayload(deviceID: localDeviceID, nonce: localNonce)
        let proof = Data(HMAC<SHA256>.authenticationCode(for: payload, using: workspaceKey))
        let hello = ClipboardChannelHello(
            version: ClipboardEnvelope.protocolVersion,
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
        let hello = try JSONDecoder().decode(ClipboardChannelHello.self, from: payload)
        guard hello.version == ClipboardEnvelope.protocolVersion,
              hello.workspaceID == workspaceID,
              hello.deviceID != localDeviceID,
              hello.nonce.count == 32,
              hello.proof.count == 32,
              expectedDeviceID == nil || expectedDeviceID == hello.deviceID else {
            throw NetworkClipboardError.authenticationFailed
        }
        let proofPayload = helloProofPayload(deviceID: hello.deviceID, nonce: hello.nonce)
        guard HMAC<SHA256>.isValidAuthenticationCode(
            hello.proof,
            authenticating: proofPayload,
            using: workspaceKey
        ) else {
            throw NetworkClipboardError.authenticationFailed
        }

        let localFirst = localDeviceID < hello.deviceID
        let salt = localFirst ? localNonce + hello.nonce : hello.nonce + localNonce
        let info = Data(
            "UniSpace clipboard channel v1|\(workspaceID.rawValue.uuidString)".utf8
        )
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: workspaceKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        let shouldNotify = lock.clipboardWithLock { () -> Bool in
            guard sessionKey == nil else { return false }
            sessionKey = derived
            authenticatedDeviceID = hello.deviceID
            return true
        }
        if shouldNotify { authenticatedHandler?(hello.deviceID) }
    }

    private func seal(_ data: Data) throws -> Data {
        let values = try lock.clipboardWithLock { () throws -> (SymmetricKey, UInt64) in
            guard let sessionKey else { throw NetworkClipboardError.authenticationFailed }
            let sequence = outboundSequence
            let (next, overflow) = outboundSequence.addingReportingOverflow(1)
            guard !overflow else { throw NetworkClipboardError.replayedFrame }
            outboundSequence = next
            return (sessionKey, sequence)
        }
        var plaintext = Data()
        var sequence = values.1.bigEndian
        Swift.withUnsafeBytes(of: &sequence) { plaintext.append(contentsOf: $0) }
        plaintext.append(data)
        let sealed = try ChaChaPoly.seal(plaintext, using: values.0)
        return Self.outerFrame(kind: .sealed, payload: sealed.combined)
    }

    private func open(_ payload: Data) throws -> Data {
        let key = try lock.clipboardWithLock { () throws -> SymmetricKey in
            guard let sessionKey else { throw NetworkClipboardError.authenticationFailed }
            return sessionKey
        }
        let box = try ChaChaPoly.SealedBox(combined: payload)
        let plaintext = try ChaChaPoly.open(box, using: key)
        guard plaintext.count >= 8 else { throw NetworkClipboardError.malformedPacket }
        let sequence = plaintext.prefix(8).reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        try lock.clipboardWithLock {
            if let inboundSequence, sequence <= inboundSequence {
                throw NetworkClipboardError.replayedFrame
            }
            inboundSequence = sequence
        }
        return Data(plaintext.dropFirst(8))
    }

    private func helloProofPayload(deviceID: DeviceID, nonce: Data) -> Data {
        var data = Data("UniSpace secure clipboard hello v1".utf8)
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
        let packets: [(ClipboardPacketKind, Data)]? = lock.clipboardWithLock {
            buffer.append(data)
            var packets: [(ClipboardPacketKind, Data)] = []
            while buffer.count >= 5 {
                let length = Int(buffer.prefix(4).reduce(UInt32(0)) {
                    ($0 << 8) | UInt32($1)
                })
                let kindIndex = buffer.index(buffer.startIndex, offsetBy: 4)
                guard length <= ClipboardFrameCodec.maximumEncodedSize + 64,
                      let kind = ClipboardPacketKind(rawValue: buffer[kindIndex]) else {
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
        kind: ClipboardPacketKind,
        payload: Data
    ) -> Data {
        var result = Data()
        var length = UInt32(payload.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(kind.rawValue)
        result.append(payload)
        return result
    }
}

private extension NSLock {
    @inline(__always)
    func clipboardWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
