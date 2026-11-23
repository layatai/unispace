import CryptoKit
import Foundation
import Network
import OSLog
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
    private let listenerRetryDelays: [TimeInterval]
    private let unexpectedPeerGrace: TimeInterval
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
    /// Authenticated workspace peers that connected before this Mac selected
    /// them as the clipboard destination. Activation reaches the peer over the
    /// control channel before the Mac's continuity context updates the desired
    /// peer, so the peer's first dial often wins that race. Parking keeps the
    /// authenticated channel open briefly instead of closing it.
    private var parkedConnections: [DeviceID: SecureClipboardConnection] = [:]
    /// Updates that arrived on a parked connection. The peer already treats
    /// them as sent, so they are delivered after promotion rather than dropped.
    private var parkedUpdates: [ObjectIdentifier: [ClipboardEnvelope]] = [:]
    private static let maximumParkedUpdates = 8
    private var retryAttempts: [DeviceID: Int] = [:]
    private var retryTokens: [DeviceID: UUID] = [:]
    private var desiredPeerID: DeviceID?
    private var listenerRetryAttempt = 0
    private var listenerRetryToken: UUID?
    private var running = false

    public init(
        listenPort: NWEndpoint.Port = NetworkClipboardTransport.clipboardPort,
        directPort: NWEndpoint.Port = NetworkClipboardTransport.clipboardPort,
        enableBonjour: Bool = true,
        listenerRetryDelays: [TimeInterval] = [1, 2, 4, 8, 15],
        unexpectedPeerGrace: TimeInterval = 3
    ) {
        self.unexpectedPeerGrace = max(unexpectedPeerGrace, 0)
        configuredListenPort = listenPort
        configuredDirectPort = directPort
        self.enableBonjour = enableBonjour
        self.listenerRetryDelays = listenerRetryDelays.isEmpty ? [1] : listenerRetryDelays
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
            listenerRetryAttempt = 0
            listenerRetryToken = nil
            running = true
        }

        let listener = try makeListener(localDevice: localDevice, workspaceID: workspace.id)
        let browser: NWBrowser?
        if enableBonjour {
            let value = NWBrowser(
                for: .bonjour(type: Self.serviceType, domain: nil),
                using: Self.makeParameters()
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
            browser = value
        } else {
            browser = nil
        }

        lock.clipboardWithLock {
            self.listener = listener
            self.browser = browser
        }
        listener.start(queue: queue)
        browser?.start(queue: queue)

    }

    public func stop() async { stopSynchronously() }

    public func setDesiredPeer(_ deviceID: DeviceID?) {
        queue.async { [weak self] in
            guard let self else { return }
            let cancelled = self.lock.clipboardWithLock { () -> [SecureClipboardConnection] in
                if self.desiredPeerID != deviceID {
                    Self.logger.info(
                        "Clipboard desired peer \(Self.label(self.desiredPeerID), privacy: .public) -> \(Self.label(deviceID), privacy: .public)"
                    )
                }
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
                let staleActive = self.connections.filter { $0.key != deviceID }.map(\.value)
                return stale.map(\.value) + staleActive
            }
            cancelled.forEach { $0.cancel() }
            guard let deviceID else { return }
            let parked = self.lock.clipboardWithLock {
                self.parkedConnections.removeValue(forKey: deviceID)
            }
            if let parked {
                Self.logger.info(
                    "Clipboard promoting parked inbound connection from \(Self.label(deviceID), privacy: .public)"
                )
                self.register(parked, as: deviceID, objectID: ObjectIdentifier(parked))
            }
            let ownsDial = self.lock.clipboardWithLock {
                PeerConnectionPolicy.macCanDial(self.knownPeers[deviceID]) &&
                    (self.localDevice.map { $0.id < deviceID } ?? false)
            }
            if ownsDial { self.scheduleDirectConnection(to: deviceID, immediately: true) }
        }
    }

    public func send(_ envelope: ClipboardEnvelope, to deviceID: DeviceID) async throws {
        guard let connection = lock.clipboardWithLock({ connections[deviceID] }) else {
            Self.logger.error(
                "Clipboard send to \(Self.label(deviceID), privacy: .public) failed: no registered connection"
            )
            throw NetworkClipboardError.peerUnavailable(deviceID)
        }
        let frame = try ClipboardFrameCodec.encode(envelope)
        Self.logger.info(
            "Clipboard send to \(Self.label(deviceID), privacy: .public) via \(connection.directionLabel, privacy: .public) connection, \(frame.count, privacy: .public) bytes"
        )
        try await connection.send(frame)
    }

    private func stopSynchronously() {
        let values: (NWListener?, NWBrowser?, [SecureClipboardConnection]) = lock.clipboardWithLock {
            let values = (
                listener,
                browser,
                Array(connections.values) + Array(pendingConnections.values) +
                    Array(parkedConnections.values)
            )
            listener = nil
            browser = nil
            readyPort = nil
            connections.removeAll()
            pendingConnections.removeAll()
            parkedConnections.removeAll()
            parkedUpdates.removeAll()
            retryAttempts.removeAll()
            retryTokens.removeAll()
            desiredPeerID = nil
            listenerRetryAttempt = 0
            listenerRetryToken = nil
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
            lock.clipboardWithLock {
                guard self.listener === listener else { return }
                readyPort = listener?.port
                listenerRetryAttempt = 0
                listenerRetryToken = nil
            }
        case .failed, .waiting:
            let shouldRetry = lock.clipboardWithLock { () -> Bool in
                guard running, self.listener === listener else { return false }
                self.listener = nil
                readyPort = nil
                return true
            }
            guard shouldRetry else { return }
            listener?.cancel()
            emit(.failure(nil))
            scheduleListenerRestart()
        default:
            break
        }
    }

    private func makeListener(
        localDevice: DeviceDescriptor,
        workspaceID: WorkspaceID
    ) throws -> NWListener {
        let listener = try NWListener(using: Self.makeParameters(), on: configuredListenPort)
        if enableBonjour {
            listener.service = NWListener.Service(
                name: localDevice.name,
                type: Self.serviceType,
                txtRecord: NWTXTRecord([
                    "device": localDevice.id.rawValue.uuidString,
                    "workspace": workspaceID.rawValue.uuidString,
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
        return listener
    }

    private func scheduleListenerRestart() {
        let schedule: (UUID, TimeInterval)? = lock.clipboardWithLock {
            guard running,
                  listener == nil,
                  listenerRetryToken == nil else { return nil }
            let token = UUID()
            let delay = listenerRetryDelays[
                min(listenerRetryAttempt, listenerRetryDelays.count - 1)
            ]
            listenerRetryAttempt += 1
            listenerRetryToken = token
            return (token, delay)
        }
        guard let (token, delay) = schedule else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restartListener(token: token)
        }
    }

    private func restartListener(token: UUID) {
        let configuration: (DeviceDescriptor, WorkspaceID)? = lock.clipboardWithLock {
            guard running,
                  listener == nil,
                  listenerRetryToken == token,
                  let localDevice,
                  let workspaceID else { return nil }
            listenerRetryToken = nil
            return (localDevice, workspaceID)
        }
        guard let (localDevice, workspaceID) = configuration else { return }

        do {
            let listener = try makeListener(localDevice: localDevice, workspaceID: workspaceID)
            let installed = lock.clipboardWithLock { () -> Bool in
                guard running, self.listener == nil else { return false }
                self.listener = listener
                return true
            }
            guard installed else {
                listener.cancel()
                return
            }
            listener.start(queue: queue)
        } catch {
            emit(.failure(nil))
            scheduleListenerRestart()
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
            guard deviceID != configuration.0.id,
                  configuration.0.id < deviceID,
                  deviceID == lock.clipboardWithLock({ desiredPeerID }) else { continue }

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
                let parked = self.lock.clipboardWithLock { () -> Bool in
                    guard self.parkedConnections[deviceID] === secure else { return false }
                    var updates = self.parkedUpdates[objectID, default: []]
                    updates.append(envelope)
                    self.parkedUpdates[objectID] = Array(updates.suffix(Self.maximumParkedUpdates))
                    return true
                }
                if parked {
                    Self.logger.info(
                        "Clipboard buffered an update from parked peer \(Self.label(deviceID), privacy: .public)"
                    )
                    return
                }
                self.emit(.update(deviceID, envelope))
            } catch {
                self.emit(.failure(deviceID))
                secure.cancel()
            }
        }
    }

    private enum RegistrationOutcome {
        case registered(newlyConnected: Bool, replaced: SecureClipboardConnection?)
        case parked(previous: SecureClipboardConnection?)
        case rejected(reason: String)
    }

    private func register(
        _ secure: SecureClipboardConnection,
        as deviceID: DeviceID,
        objectID: ObjectIdentifier
    ) {
        let outcome = lock.clipboardWithLock { () -> RegistrationOutcome in
            pendingConnections.removeValue(forKey: objectID)
            guard running else { return .rejected(reason: "transport stopped") }
            guard desiredPeerID == deviceID else {
                guard knownPeers[deviceID] != nil else {
                    return .rejected(reason: "unknown workspace peer")
                }
                let previous = parkedConnections[deviceID]
                parkedConnections[deviceID] = secure
                return .parked(previous: previous === secure ? nil : previous)
            }
            if parkedConnections[deviceID] === secure {
                parkedConnections.removeValue(forKey: deviceID)
            }
            var replaced: SecureClipboardConnection?
            if let existing = connections[deviceID], existing !== secure {
                if existing.isOutbound != secure.isOutbound {
                    // Simultaneous dials from both ends: keep the direction the
                    // lower device ID owns so both ends converge on one socket.
                    let localID = localDevice?.id
                    let prefersOutbound = localID.map { $0 < deviceID } ?? false
                    guard secure.isOutbound == prefersOutbound else {
                        return .rejected(reason: "duplicate; existing connection has the preferred direction")
                    }
                }
                // Same direction: the dialing side only redials after it gave up
                // on its previous socket, so the newest connection is the one it
                // reads from. Keeping the older one strands sends on a dead socket.
                replaced = existing
            }
            let newlyConnected = connections[deviceID] == nil
            connections[deviceID] = secure
            retryTokens.removeValue(forKey: deviceID)
            return .registered(newlyConnected: newlyConnected, replaced: replaced)
        }

        switch outcome {
        case let .rejected(reason):
            Self.logger.notice(
                "Clipboard rejected \(secure.directionLabel, privacy: .public) connection from \(Self.label(deviceID), privacy: .public): \(reason, privacy: .public)"
            )
            secure.cancel()
            return
        case let .parked(previous):
            Self.logger.notice(
                "Clipboard parked \(secure.directionLabel, privacy: .public) connection from \(Self.label(deviceID), privacy: .public): desired peer is \(Self.label(self.lock.clipboardWithLock { self.desiredPeerID }), privacy: .public)"
            )
            previous?.cancel()
            queue.asyncAfter(deadline: .now() + unexpectedPeerGrace) { [weak self, weak secure] in
                guard let self, let secure else { return }
                let expired = self.lock.clipboardWithLock { () -> Bool in
                    guard self.parkedConnections[deviceID] === secure else { return false }
                    self.parkedConnections.removeValue(forKey: deviceID)
                    self.parkedUpdates.removeValue(forKey: ObjectIdentifier(secure))
                    return true
                }
                guard expired else { return }
                Self.logger.notice(
                    "Clipboard closed parked connection from \(Self.label(deviceID), privacy: .public): it never became the desired peer"
                )
                secure.cancel()
            }
            return
        case let .registered(newlyConnected, replaced):
            Self.logger.info(
                "Clipboard accepted \(secure.directionLabel, privacy: .public) connection from \(Self.label(deviceID), privacy: .public)\(replaced == nil ? "" : ", replacing an older one", privacy: .public)"
            )
            replaced?.cancel()
            if newlyConnected { emit(.connected(deviceID)) }
            let buffered = lock.clipboardWithLock {
                parkedUpdates.removeValue(forKey: ObjectIdentifier(secure)) ?? []
            }
            for envelope in buffered { emit(.update(deviceID, envelope)) }
        }
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak secure] in
            guard let self, let secure else { return }
            self.lock.clipboardWithLock {
                guard self.connections[deviceID] === secure else { return }
                self.retryAttempts[deviceID] = 0
            }
        }
    }

    private func remove(
        _ secure: SecureClipboardConnection,
        objectID: ObjectIdentifier,
        expectedDeviceID: DeviceID?
    ) {
        let removedDeviceID: DeviceID? = lock.clipboardWithLock {
            pendingConnections.removeValue(forKey: objectID)
            parkedUpdates.removeValue(forKey: ObjectIdentifier(secure))
            if let deviceID = secure.deviceID, parkedConnections[deviceID] === secure {
                parkedConnections.removeValue(forKey: deviceID)
            }
            guard let deviceID = secure.deviceID,
                  connections[deviceID] === secure else { return nil }
            connections.removeValue(forKey: deviceID)
            return deviceID
        }
        if let removedDeviceID {
            Self.logger.info(
                "Clipboard connection to \(Self.label(removedDeviceID), privacy: .public) closed"
            )
            emit(.disconnected(removedDeviceID))
            scheduleDirectConnection(to: removedDeviceID, immediately: false)
        } else if let expectedDeviceID {
            scheduleDirectConnection(to: expectedDeviceID, immediately: false)
        }
    }

    private func scheduleDirectConnection(to deviceID: DeviceID, immediately: Bool) {
        let schedule: (UUID, TimeInterval)? = lock.clipboardWithLock {
            guard running,
                  desiredPeerID == deviceID,
                  PeerConnectionPolicy.macCanDial(knownPeers[deviceID]),
                  localDevice.map({ $0.id < deviceID }) == true,
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

    static let logger = ClipboardDiagnostics.logger("clipboard.transport")

    static func label(_ deviceID: DeviceID?) -> String { ClipboardDiagnostics.label(deviceID) }

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

    var directionLabel: String { isOutbound ? "outbound" : "inbound" }

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
