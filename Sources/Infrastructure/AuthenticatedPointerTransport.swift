import Foundation
import Network
import UniSpaceApplication
import UniSpaceDomain

/// Authenticated UDP lane for replaceable pointer state.
///
/// The active macOS controller is the only proactive Mac dialer. Windows keeps
/// initiating its existing receiver flow, so this remains wire-compatible with
/// Macifier while avoiding TCP head-of-line blocking for Mac-to-Mac pointer data.
final class AuthenticatedPointerTransport: @unchecked Sendable {
    var frameHandler: (@Sendable (DeviceID, PortableRealtimePointerFrame) -> Void)?

    private let queue = DispatchQueue(label: "com.layatai.unispace.pointer", qos: .userInteractive)
    private let lock = NSLock()
    private let listenPort: NWEndpoint.Port
    private let directPort: NWEndpoint.Port
    private var localDevice: DeviceDescriptor?
    private var workspaceID: WorkspaceID?
    private var key: Data?
    private var knownPeers: [DeviceID: DeviceDescriptor] = [:]
    private var listener: NWListener?
    private var readyPort: NWEndpoint.Port?
    private var connections: [DeviceID: SecurePeerConnection] = [:]
    private var pending: [ObjectIdentifier: SecurePeerConnection] = [:]
    private var retries: [DeviceID: Int] = [:]
    private var retryTokens: [DeviceID: UUID] = [:]
    private var desiredPeerID: DeviceID?
    private var shouldDialDesiredPeer = false
    private var running = false

    init(
        listenPort: NWEndpoint.Port = NetworkPeerTransport.crossPlatformPointerPort,
        directPort: NWEndpoint.Port = NetworkPeerTransport.crossPlatformPointerPort
    ) {
        self.listenPort = listenPort
        self.directPort = directPort
    }

    var activePort: NWEndpoint.Port? { lock.withLock { readyPort } }

    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) throws {
        stop()
        let listener = try NWListener(using: .udp, on: listenPort)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port { self?.lock.withLock { self?.readyPort = port } }
            case .failed:
                self?.stop()
            default:
                break
            }
        }
        lock.withLock {
            self.localDevice = localDevice
            workspaceID = workspace.id
            self.key = key
            knownPeers = Dictionary(
                uniqueKeysWithValues: workspace.devices
                    .filter { $0.id != localDevice.id }
                    .map { ($0.id, $0) }
            )
            self.listener = listener
            running = true
        }
        listener.start(queue: queue)
    }

    func setDesiredPeer(_ deviceID: DeviceID?, shouldDial: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let cancelled = self.lock.withLock { () -> [SecurePeerConnection] in
                self.desiredPeerID = deviceID
                self.shouldDialDesiredPeer = shouldDial

                let staleRetryIDs = self.retryTokens.keys.filter {
                    $0 != deviceID || !shouldDial
                }
                for id in staleRetryIDs {
                    self.retryTokens.removeValue(forKey: id)
                    self.retries.removeValue(forKey: id)
                }

                let stalePending = self.pending.filter {
                    guard $0.value.isOutbound else { return false }
                    return $0.value.expectedDeviceID != deviceID || !shouldDial
                }
                for (objectID, _) in stalePending { self.pending.removeValue(forKey: objectID) }

                let staleMacConnections = self.connections.filter { id, connection in
                    self.knownPeers[id]?.platform != .windows &&
                        (id != deviceID || (!shouldDial && connection.isOutbound))
                }
                for (id, _) in staleMacConnections { self.connections.removeValue(forKey: id) }
                return stalePending.map(\.value) + staleMacConnections.map(\.value)
            }
            cancelled.forEach { $0.cancel() }
            if let deviceID, shouldDial {
                self.scheduleDirectConnection(to: deviceID, immediately: true)
            }
        }
    }

    func stop() {
        let values = lock.withLock { () -> (NWListener?, [SecurePeerConnection]) in
            let values = (listener, Array(connections.values) + Array(pending.values))
            listener = nil
            readyPort = nil
            connections.removeAll()
            pending.removeAll()
            retries.removeAll()
            retryTokens.removeAll()
            desiredPeerID = nil
            shouldDialDesiredPeer = false
            knownPeers.removeAll()
            localDevice = nil
            workspaceID = nil
            key = nil
            running = false
            return values
        }
        values.0?.cancel()
        values.1.forEach { $0.cancel() }
    }

    func send(_ frame: PortableRealtimePointerFrame, to deviceID: DeviceID) async throws -> Bool {
        sendImmediately(frame, to: deviceID)
    }

    func sendImmediately(_ frame: PortableRealtimePointerFrame, to deviceID: DeviceID) -> Bool {
        guard let connection = lock.withLock({ connections[deviceID] }) else { return false }
        do {
            let payload = try WireFrameCodec.encodePortableRealtimePointer(frame)
            connection.send(payload) { [weak connection] error in
                if error != nil { connection?.cancel() }
            }
            return true
        } catch {
            connection.cancel()
            return false
        }
    }

    func reconnect(to deviceID: DeviceID) {
        queue.async { [weak self] in
            guard let self else { return }
            let cancelled = self.lock.withLock { () -> [SecurePeerConnection] in
                guard self.running, self.desiredPeerID == deviceID,
                      self.shouldDialDesiredPeer else { return [] }
                self.retryTokens.removeValue(forKey: deviceID)
                self.retries[deviceID] = 0
                let pending = self.pending.filter { $0.value.expectedDeviceID == deviceID }
                for (objectID, _) in pending { self.pending.removeValue(forKey: objectID) }
                let active = self.connections.removeValue(forKey: deviceID)
                return pending.map(\.value) + [active].compactMap { $0 }
            }
            cancelled.forEach { $0.cancel() }
            self.scheduleDirectConnection(to: deviceID, immediately: true)
        }
    }

    private func accept(_ connection: NWConnection) {
        install(connection, expectedDeviceID: nil, isOutbound: false)
        connection.start(queue: queue)
    }

    private func connect(to peer: DeviceDescriptor, address: PeerAddress) {
        let connection = NWConnection(
            host: NWEndpoint.Host(address.host),
            port: directPort,
            using: .udp
        )
        install(connection, expectedDeviceID: peer.id, isOutbound: true)
        connection.start(queue: queue)
    }

    private func install(
        _ connection: NWConnection,
        expectedDeviceID: DeviceID?,
        isOutbound: Bool
    ) {
        guard let configuration = lock.withLock({ () -> (DeviceID, WorkspaceID, Data)? in
            guard running, let localDevice, let workspaceID, let key else { return nil }
            return (localDevice.id, workspaceID, key)
        }) else {
            connection.cancel()
            return
        }
        let managed = SecurePeerConnection(
            connection: connection,
            localDeviceID: configuration.0,
            workspaceID: configuration.1,
            workspaceKey: configuration.2,
            expectedDeviceID: expectedDeviceID,
            isOutbound: isOutbound,
            transportKind: .tcp,
            isDatagram: true,
            securityProfile: .pointerV2
        )
        let objectID = ObjectIdentifier(managed)
        lock.withLock { pending[objectID] = managed }
        managed.authenticatedHandler = { [weak self, weak managed] deviceID in
            guard let self, let managed else { return }
            self.register(managed, as: deviceID, objectID: objectID)
        }
        managed.frameHandler = { [weak self, weak managed] kind, payload in
            guard let self, let managed, let deviceID = managed.deviceID,
                  kind == .realtimePointerBinaryV2,
                  let frame = try? WireFrameCodec.decodePortableRealtimePointer(payload),
                  frame.controllerID == deviceID else { return }
            self.frameHandler?(deviceID, frame)
        }
        managed.stateHandler = { [weak self, weak managed] state in
            guard let self, let managed, state == .cancelled || Self.isFailure(state) else { return }
            self.remove(managed, objectID: objectID, expectedDeviceID: expectedDeviceID)
        }
    }

    private func register(
        _ candidate: SecurePeerConnection,
        as deviceID: DeviceID,
        objectID: ObjectIdentifier
    ) {
        var replaced: SecurePeerConnection?
        var rejected = false
        lock.withLock {
            pending.removeValue(forKey: objectID)
            guard let peer = knownPeers[deviceID] else {
                rejected = true
                return
            }
            if peer.platform != .windows, desiredPeerID != deviceID {
                // The controller's UDP hello can overtake its activation frame
                // on the established TCP channel. Keep that authenticated
                // inbound lane warm; session state still rejects early input.
                guard desiredPeerID == nil, !candidate.isOutbound else {
                    rejected = true
                    return
                }
            }
            if let existing = connections[deviceID], existing !== candidate {
                if peer.platform == .windows, !candidate.isOutbound {
                    connections[deviceID] = candidate
                    replaced = existing
                } else {
                    let preferOutbound = peer.platform != .windows && shouldDialDesiredPeer
                    if candidate.isOutbound == preferOutbound && existing.isOutbound != preferOutbound {
                        connections[deviceID] = candidate
                        replaced = existing
                    } else {
                        rejected = true
                    }
                }
            } else {
                connections[deviceID] = candidate
            }
            retryTokens.removeValue(forKey: deviceID)
        }
        if rejected {
            candidate.cancel()
            return
        }
        replaced?.cancel()
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            self.lock.withLock {
                guard self.connections[deviceID] === candidate else { return }
                self.retries[deviceID] = 0
            }
        }
    }

    private func remove(
        _ connection: SecurePeerConnection,
        objectID: ObjectIdentifier,
        expectedDeviceID: DeviceID?
    ) {
        let reconnectID = lock.withLock { () -> DeviceID? in
            pending.removeValue(forKey: objectID)
            guard let deviceID = connection.deviceID ?? expectedDeviceID else { return nil }
            if connections[deviceID] === connection { connections.removeValue(forKey: deviceID) }
            return deviceID
        }
        if let reconnectID { scheduleDirectConnection(to: reconnectID, immediately: false) }
    }

    private func scheduleDirectConnection(to deviceID: DeviceID, immediately: Bool) {
        let schedule = lock.withLock { () -> (UUID, TimeInterval)? in
            guard running, desiredPeerID == deviceID, shouldDialDesiredPeer,
                  let peer = knownPeers[deviceID], peer.platform != .windows,
                  peer.capabilities.contains(.udpPointerV2), !peer.peerAddresses.isEmpty,
                  connections[deviceID] == nil, retryTokens[deviceID] == nil else { return nil }
            let attempt = retries[deviceID, default: 0]
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
        let target = lock.withLock { () -> (DeviceDescriptor, PeerAddress)? in
            guard running, desiredPeerID == deviceID, shouldDialDesiredPeer,
                  retryTokens[deviceID] == token, connections[deviceID] == nil,
                  !pending.values.contains(where: { $0.expectedDeviceID == deviceID }),
                  let peer = knownPeers[deviceID], peer.platform != .windows,
                  peer.capabilities.contains(.udpPointerV2), !peer.peerAddresses.isEmpty else {
                retryTokens.removeValue(forKey: deviceID)
                return nil
            }
            retryTokens.removeValue(forKey: deviceID)
            let attempt = retries[deviceID, default: 0]
            retries[deviceID] = attempt + 1
            return (peer, peer.peerAddresses[attempt % peer.peerAddresses.count])
        }
        guard let (peer, address) = target else { return }
        connect(to: peer, address: address)
    }

    private static func isFailure(_ state: NWConnection.State) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
