import CryptoKit
import Foundation
import Network
import UniSpaceApplication
import UniSpaceDomain

public enum PeerTransportError: Error, Equatable {
    case notStarted
    case peerUnavailable(DeviceID)
    case sendFailed(String)
    case invalidConfiguration
    case authenticationFailed
    case replayedFrame
}

public final class NetworkPeerTransport: PeerTransport, @unchecked Sendable {
    public static let serviceType = "_unispace._tcp"

    private let queue = DispatchQueue(label: "com.layatai.unispace.network", qos: .userInteractive)
    private let lock = NSLock()
    private let stream: AsyncStream<PeerEvent>
    private let continuation: AsyncStream<PeerEvent>.Continuation
    private var localDevice: DeviceDescriptor?
    private var workspaceID: WorkspaceID?
    private var key: Data?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [DeviceID: SecurePeerConnection] = [:]
    private var pendingConnections: [ObjectIdentifier: SecurePeerConnection] = [:]
    private var discoveredDevices: [DeviceID: DeviceDescriptor] = [:]

    public init() {
        var captured: AsyncStream<PeerEvent>.Continuation?
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured!
    }

    deinit { continuation.finish() }

    public func events() -> AsyncStream<PeerEvent> { stream }

    public func start(localDevice: DeviceDescriptor, workspaceID: WorkspaceID, key: Data) async throws {
        guard key.count >= 32 else { throw PeerTransportError.invalidConfiguration }
        stopSynchronously()
        lock.withLock {
            self.localDevice = localDevice
            self.workspaceID = workspaceID
            self.key = key
        }

        let parameters = Self.makeParameters()
        let listener = try NWListener(using: parameters, on: .any)
        let record = NWTXTRecord([
            "device": localDevice.id.rawValue.uuidString,
            "name": localDevice.name,
            "workspace": workspaceID.rawValue.uuidString,
            "version": String(ControlEnvelope.protocolVersion)
        ])
        listener.service = NWListener.Service(name: localDevice.name, type: Self.serviceType, txtRecord: record)
        listener.stateUpdateHandler = { [weak self] state in self?.handleListenerState(state) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)

        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state { self?.emit(.failure(nil, error.localizedDescription)) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.handle(results) }
        browser.start(queue: queue)
        lock.withLock {
            self.listener = listener
            self.browser = browser
        }
    }

    public func stop() async { stopSynchronously() }

    public func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws {
        try await send(data: WireFrameCodec.encodeControl(envelope), to: deviceID)
    }

    public func send(_ frame: InputFrame, to deviceID: DeviceID) async throws {
        try await send(data: WireFrameCodec.encodeInput(frame), to: deviceID)
    }

    private func send(data: Data, to deviceID: DeviceID) async throws {
        guard let connection = lock.withLock({ connections[deviceID] }) else {
            throw PeerTransportError.peerUnavailable(deviceID)
        }
        try await connection.send(data)
    }

    private func stopSynchronously() {
        let values: (NWListener?, NWBrowser?, [SecurePeerConnection]) = lock.withLock {
            let active = Array(connections.values) + Array(pendingConnections.values)
            let values = (listener, browser, active)
            listener = nil
            browser = nil
            connections.removeAll()
            pendingConnections.removeAll()
            discoveredDevices.removeAll()
            return values
        }
        values.0?.cancel()
        values.1?.cancel()
        values.2.forEach { $0.cancel() }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case let .failed(error), let .waiting(error): emit(.failure(nil, error.localizedDescription))
        default: break
        }
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        lock.lock()
        guard let localDevice, let workspaceID else { lock.unlock(); return }
        let previous = Set(discoveredDevices.keys)
        var current: [DeviceID: DeviceDescriptor] = [:]
        var candidates: [(DeviceDescriptor, NWEndpoint)] = []
        for result in results {
            guard case let .bonjour(record) = result.metadata,
                  record["workspace"] == workspaceID.rawValue.uuidString,
                  let deviceString = record["device"], let uuid = UUID(uuidString: deviceString) else { continue }
            let id = DeviceID(rawValue: uuid)
            guard id != localDevice.id else { continue }
            let device = DeviceDescriptor(id: id, name: record["name"] ?? "Mac")
            current[id] = device
            if localDevice.id < id, connections[id] == nil,
               !pendingConnections.values.contains(where: { $0.expectedDeviceID == id }) {
                candidates.append((device, result.endpoint))
            }
        }
        discoveredDevices = current
        let added = Set(current.keys).subtracting(previous)
        let removed = previous.subtracting(current.keys)
        lock.unlock()

        for id in added { if let descriptor = current[id] { emit(.discovered(descriptor)) } }
        for id in removed { emit(.lost(id)) }
        for (device, endpoint) in candidates { connect(to: endpoint, expectedDevice: device) }
    }

    private func connect(to endpoint: NWEndpoint, expectedDevice: DeviceDescriptor) {
        let connection = NWConnection(to: endpoint, using: Self.makeParameters())
        install(connection, expectedDeviceID: expectedDevice.id)
        connection.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        install(connection, expectedDeviceID: nil)
        connection.start(queue: queue)
    }

    private func install(_ connection: NWConnection, expectedDeviceID: DeviceID?) {
        let configuration = lock.withLock { () -> (DeviceID, WorkspaceID, Data)? in
            guard let localDevice, let workspaceID, let key else { return nil }
            return (localDevice.id, workspaceID, key)
        }
        guard let configuration else { connection.cancel(); return }
        let managed = SecurePeerConnection(
            connection: connection,
            localDeviceID: configuration.0,
            workspaceID: configuration.1,
            workspaceKey: configuration.2,
            expectedDeviceID: expectedDeviceID
        )
        let objectID = ObjectIdentifier(managed)
        lock.withLock { pendingConnections[objectID] = managed }
        managed.stateHandler = { [weak self, weak managed] state in
            guard let self, let managed else { return }
            self.handleConnectionState(state, managed: managed, objectID: objectID, expectedDeviceID: expectedDeviceID)
        }
        managed.authenticatedHandler = { [weak self, weak managed] deviceID in
            guard let self, let managed else { return }
            self.register(managed, as: deviceID, objectID: objectID)
            let hello = self.lock.withLock { self.localDevice.map { ControlEnvelope(message: .hello($0)) } }
            if let hello, let data = try? WireFrameCodec.encodeControl(hello) { managed.send(data, completion: nil) }
        }
        managed.frameHandler = { [weak self, weak managed] kind, payload in
            guard let self, let managed else { return }
            self.handleFrame(kind: kind, payload: payload, managed: managed)
        }
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        managed: SecurePeerConnection,
        objectID: ObjectIdentifier,
        expectedDeviceID: DeviceID?
    ) {
        switch state {
        case let .failed(error), let .waiting(error):
            emit(.failure(expectedDeviceID, error.localizedDescription))
            if case .failed = state { remove(managed, objectID: objectID) }
        case .cancelled:
            remove(managed, objectID: objectID)
        default:
            break
        }
    }

    private func handleFrame(kind: WireFrameKind, payload: Data, managed: SecurePeerConnection) {
        do {
            guard let deviceID = managed.deviceID else { throw PeerTransportError.authenticationFailed }
            switch kind {
            case .controlJSON:
                let envelope = try WireFrameCodec.decodeControl(payload)
                if case let .hello(device) = envelope.message, device.id != deviceID {
                    throw PeerTransportError.authenticationFailed
                }
                emit(.control(deviceID, envelope))
            case .inputBinary:
                let frame = try WireFrameCodec.decodeInput(payload)
                guard frame.controllerID == deviceID else { throw ControlProtocolError.malformedFrame }
                emit(.input(deviceID, frame))
            }
        } catch {
            emit(.failure(managed.deviceID, String(describing: error)))
            managed.cancel()
        }
    }

    private func register(_ managed: SecurePeerConnection, as deviceID: DeviceID, objectID: ObjectIdentifier) {
        lock.lock()
        if let existing = connections[deviceID], existing !== managed { existing.cancel() }
        let wasConnected = connections[deviceID] != nil
        connections[deviceID] = managed
        pendingConnections.removeValue(forKey: objectID)
        lock.unlock()
        if !wasConnected { emit(.connected(deviceID)) }
    }

    private func remove(_ managed: SecurePeerConnection, objectID: ObjectIdentifier) {
        lock.lock()
        pendingConnections.removeValue(forKey: objectID)
        let deviceID = managed.deviceID
        if let deviceID, connections[deviceID] === managed { connections.removeValue(forKey: deviceID) }
        lock.unlock()
        if let deviceID { emit(.disconnected(deviceID)) }
    }

    private func emit(_ event: PeerEvent) { continuation.yield(event) }

    static func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

private enum SecurePacketKind: UInt8 {
    case hello = 10
    case sealed = 11
}

private struct SecureChannelHello: Codable, Sendable {
    let version: UInt16
    let workspaceID: WorkspaceID
    let deviceID: DeviceID
    let nonce: Data
    let proof: Data
}

final class SecurePeerConnection: @unchecked Sendable {
    let connection: NWConnection
    let expectedDeviceID: DeviceID?
    var stateHandler: (@Sendable (NWConnection.State) -> Void)?
    var authenticatedHandler: (@Sendable (DeviceID) -> Void)?
    var frameHandler: (@Sendable (WireFrameKind, Data) -> Void)?

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

    var deviceID: DeviceID? { lock.withLock { authenticatedDeviceID } }

    init(
        connection: NWConnection,
        localDeviceID: DeviceID,
        workspaceID: WorkspaceID,
        workspaceKey: Data,
        expectedDeviceID: DeviceID?
    ) {
        self.connection = connection
        self.localDeviceID = localDeviceID
        self.workspaceID = workspaceID
        self.workspaceKey = SymmetricKey(data: workspaceKey)
        self.expectedDeviceID = expectedDeviceID
        self.localNonce = PairingCryptoSession.randomData(count: 32)
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateHandler?(state)
            if case .ready = state {
                self?.receiveNext()
                self?.sendHello()
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(data) { error in
                if let error { continuation.resume(throwing: PeerTransportError.sendFailed(error.localizedDescription)) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func send(_ data: Data, completion: (@Sendable (NWError?) -> Void)?) {
        do {
            let outer = try seal(data)
            connection.send(content: outer, completion: .contentProcessed { error in completion?(error) })
        } catch {
            completion?(NWError.posix(.EAUTH))
            cancel()
        }
    }

    func cancel() { connection.cancel() }

    private func sendHello() {
        let unsigned = helloProofPayload(deviceID: localDeviceID, nonce: localNonce)
        let proof = Data(HMAC<SHA256>.authenticationCode(for: unsigned, using: workspaceKey))
        let hello = SecureChannelHello(
            version: 1,
            workspaceID: workspaceID,
            deviceID: localDeviceID,
            nonce: localNonce,
            proof: proof
        )
        guard let payload = try? JSONEncoder().encode(hello) else { cancel(); return }
        connection.send(content: Self.outerFrame(kind: .hello, payload: payload), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.cancel() }
        })
    }

    private func handleHello(_ payload: Data) throws {
        let hello = try JSONDecoder().decode(SecureChannelHello.self, from: payload)
        guard hello.version == 1, hello.workspaceID == workspaceID,
              expectedDeviceID == nil || expectedDeviceID == hello.deviceID else {
            throw PeerTransportError.authenticationFailed
        }
        let proofPayload = helloProofPayload(deviceID: hello.deviceID, nonce: hello.nonce)
        guard HMAC<SHA256>.isValidAuthenticationCode(hello.proof, authenticating: proofPayload, using: workspaceKey) else {
            throw PeerTransportError.authenticationFailed
        }
        let localFirst = localDeviceID < hello.deviceID
        let salt = localFirst ? localNonce + hello.nonce : hello.nonce + localNonce
        let info = Data("UniSpace channel v1|\(workspaceID.rawValue.uuidString)".utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: workspaceKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        let shouldNotify = lock.withLock { () -> Bool in
            guard sessionKey == nil else { return false }
            sessionKey = derived
            authenticatedDeviceID = hello.deviceID
            return true
        }
        if shouldNotify { authenticatedHandler?(hello.deviceID) }
    }

    private func seal(_ data: Data) throws -> Data {
        let values = try lock.withLock { () throws -> (SymmetricKey, UInt64) in
            guard let sessionKey else { throw PeerTransportError.authenticationFailed }
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
        let key = try lock.withLock { () throws -> SymmetricKey in
            guard let sessionKey else { throw PeerTransportError.authenticationFailed }
            return sessionKey
        }
        let box = try ChaChaPoly.SealedBox(combined: payload)
        let plaintext = try ChaChaPoly.open(box, using: key)
        guard plaintext.count >= 8 else { throw ControlProtocolError.malformedFrame }
        let sequence = plaintext.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        try lock.withLock {
            if let inboundSequence, sequence <= inboundSequence { throw PeerTransportError.replayedFrame }
            inboundSequence = sequence
        }
        return plaintext.dropFirst(8)
    }

    private func helloProofPayload(deviceID: DeviceID, nonce: Data) -> Data {
        var data = Data("UniSpace secure hello v1".utf8)
        data.append(Data(workspaceID.rawValue.uuidString.utf8))
        data.append(Data(deviceID.rawValue.uuidString.utf8))
        data.append(nonce)
        return data
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if error == nil, !complete { self.receiveNext() }
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var packets: [(SecurePacketKind, Data)] = []
        while buffer.count >= 5 {
            let length = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            let kindIndex = buffer.index(buffer.startIndex, offsetBy: 4)
            guard length <= WireFrameCodec.maximumPayloadSize + 64,
                  let kind = SecurePacketKind(rawValue: buffer[kindIndex]) else {
                buffer.removeAll(); lock.unlock(); cancel(); return
            }
            guard buffer.count >= length + 5 else { break }
            packets.append((kind, Data(buffer.dropFirst(5).prefix(length))))
            buffer.removeFirst(length + 5)
        }
        lock.unlock()

        do {
            for (kind, payload) in packets {
                switch kind {
                case .hello:
                    try handleHello(payload)
                case .sealed:
                    let inner = try open(payload)
                    let decoded = try WireFrameCodec.decode(inner)
                    frameHandler?(decoded.0, decoded.1)
                }
            }
        } catch {
            cancel()
        }
    }

    private static func outerFrame(kind: SecurePacketKind, payload: Data) -> Data {
        var result = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(kind.rawValue)
        result.append(payload)
        return result
    }
}
