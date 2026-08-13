import Foundation
import Network
import UniSpaceApplication
import UniSpaceDomain

/// Optional low-latency lane for replaceable pointer motion. All non-replaceable
/// input remains on the reliable authenticated control connection.
final class QUICRealtimeTransport: @unchecked Sendable {
    static let serviceType = "_unispace-rt._udp"

    var frameHandler: (@Sendable (DeviceID, RealtimePointerFrame) -> Void)?

    private let queue = DispatchQueue(label: "com.layatai.unispace.realtime", qos: .userInteractive)
    private let lock = NSLock()
    private let listenPort: NWEndpoint.Port
    private let directPort: NWEndpoint.Port
    private let enableBonjour: Bool
    private var localDevice: DeviceDescriptor?
    private var workspaceID: WorkspaceID?
    private var key: Data?
    private var knownPeers: [DeviceID: DeviceDescriptor] = [:]
    private var listener: NWListener?
    private var readyPort: NWEndpoint.Port?
    private var browser: NWBrowser?
    private var connections: [DeviceID: SecurePeerConnection] = [:]
    private var pending: [ObjectIdentifier: SecurePeerConnection] = [:]
    private var retries: [DeviceID: Int] = [:]
    private var retryTokens: [DeviceID: UUID] = [:]
    private var running = false

    init(listenPort: NWEndpoint.Port, directPort: NWEndpoint.Port, enableBonjour: Bool) {
        self.listenPort = listenPort
        self.directPort = directPort
        self.enableBonjour = enableBonjour
    }

    var activePort: NWEndpoint.Port? { lock.withLock { readyPort } }

    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) throws {
        stop()
        let parameters = try NetworkPeerTransport.makeQUICParameters(
            workspaceID: workspace.id,
            key: key,
            isDatagram: true
        )
        let listener = try NWListener(using: parameters, on: listenPort)
        let record = NWTXTRecord([
            "device": localDevice.id.rawValue.uuidString,
            "name": localDevice.name,
            "workspace": workspace.id.rawValue.uuidString,
            "version": "1"
        ])
        if enableBonjour {
            listener.service = NWListener.Service(
                name: localDevice.name,
                type: Self.serviceType,
                txtRecord: record
            )
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.install(connection, expectedDeviceID: nil, isOutbound: false)
            connection.start(queue: self.queue)
        }
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

        let browser: NWBrowser?
        if enableBonjour {
            let activeBrowser = NWBrowser(
                for: .bonjour(type: Self.serviceType, domain: nil),
                using: parameters
            )
            activeBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.handle(results)
            }
            activeBrowser.start(queue: queue)
            browser = activeBrowser
        } else {
            browser = nil
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
            self.browser = browser
            running = true
        }
        listener.start(queue: queue)
        for peer in workspace.devices where peer.id != localDevice.id && !peer.peerAddresses.isEmpty {
            scheduleDirectConnection(to: peer.id, immediately: true)
        }
    }

    func stop() {
        let values: (NWListener?, NWBrowser?, [SecurePeerConnection]) = lock.withLock {
            let values = (listener, browser, Array(connections.values) + Array(pending.values))
            listener = nil
            readyPort = nil
            browser = nil
            connections.removeAll()
            pending.removeAll()
            retries.removeAll()
            retryTokens.removeAll()
            knownPeers.removeAll()
            localDevice = nil
            workspaceID = nil
            key = nil
            running = false
            return values
        }
        values.0?.cancel()
        values.1?.cancel()
        values.2.forEach { $0.cancel() }
    }

    func send(_ frame: RealtimePointerFrame, to deviceID: DeviceID) async throws -> Bool {
        guard let connection = lock.withLock({ connections[deviceID] }) else { return false }
        try await connection.send(WireFrameCodec.encodeRealtimePointer(frame))
        return true
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        let candidates = lock.withLock { () -> [(DeviceID, NWEndpoint)] in
            guard let localDevice, let workspaceID else { return [] }
            return results.compactMap { result in
                guard case let .bonjour(record) = result.metadata,
                      record["workspace"] == workspaceID.rawValue.uuidString,
                      let idValue = record["device"],
                      let uuid = UUID(uuidString: idValue) else { return nil }
                let id = DeviceID(rawValue: uuid)
                guard id != localDevice.id,
                      connections[id] == nil,
                      !pending.values.contains(where: { $0.expectedDeviceID == id }) else { return nil }
                return (id, result.endpoint)
            }
        }
        for (id, endpoint) in candidates { connect(to: endpoint, expectedDeviceID: id) }
    }

    private func connect(to endpoint: NWEndpoint, expectedDeviceID: DeviceID) {
        guard let configuration = lock.withLock({ () -> (WorkspaceID, Data)? in
            guard running, let workspaceID, let key else { return nil }
            return (workspaceID, key)
        }), let parameters = try? NetworkPeerTransport.makeQUICParameters(
            workspaceID: configuration.0,
            key: configuration.1,
            isDatagram: true
        ) else { return }
        let connection = NWConnection(to: endpoint, using: parameters)
        install(connection, expectedDeviceID: expectedDeviceID, isOutbound: true)
        connection.start(queue: queue)
    }

    private func install(
        _ connection: NWConnection,
        expectedDeviceID: DeviceID?,
        isOutbound: Bool
    ) {
        guard let configuration = lock.withLock({ () -> (DeviceID, WorkspaceID, Data)? in
            guard let localDevice, let workspaceID, let key else { return nil }
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
            transportKind: .quic,
            isDatagram: true
        )
        let objectID = ObjectIdentifier(managed)
        lock.withLock { pending[objectID] = managed }
        managed.authenticatedHandler = { [weak self, weak managed] deviceID in
            guard let self, let managed else { return }
            self.register(managed, as: deviceID, objectID: objectID)
        }
        managed.frameHandler = { [weak self, weak managed] kind, payload in
            guard let self, let managed, let deviceID = managed.deviceID,
                  kind == .realtimePointerBinary,
                  let frame = try? WireFrameCodec.decodeRealtimePointer(payload),
                  frame.controllerID == deviceID else { return }
            self.frameHandler?(deviceID, frame)
        }
        managed.stateHandler = { [weak self, weak managed] state in
            guard let self, let managed else { return }
            switch state {
            case .failed, .cancelled:
                self.remove(managed, objectID: objectID, expectedDeviceID: expectedDeviceID)
            default:
                break
            }
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
            if let existing = connections[deviceID], existing !== candidate {
                guard let localID = localDevice?.id else {
                    rejected = true
                    return
                }
                let preferredOutbound = localID < deviceID
                if candidate.isOutbound == preferredOutbound && existing.isOutbound != preferredOutbound {
                    connections[deviceID] = candidate
                    replaced = existing
                } else {
                    rejected = true
                }
            } else {
                connections[deviceID] = candidate
            }
            retries[deviceID] = 0
            retryTokens.removeValue(forKey: deviceID)
        }
        if rejected { candidate.cancel() } else { replaced?.cancel() }
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
            guard running, connections[deviceID] == nil, retryTokens[deviceID] == nil,
                  knownPeers[deviceID]?.peerAddresses.isEmpty == false else { return nil }
            let attempt = retries[deviceID, default: 0]
            let delay = immediately ? 0 : min(pow(2, Double(attempt)) * 0.25, 5)
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
        let target = lock.withLock { () -> PeerAddress? in
            guard running, retryTokens[deviceID] == token, connections[deviceID] == nil,
                  let peer = knownPeers[deviceID], !peer.peerAddresses.isEmpty else {
                retryTokens.removeValue(forKey: deviceID)
                return nil
            }
            retryTokens.removeValue(forKey: deviceID)
            let attempt = retries[deviceID, default: 0]
            retries[deviceID] = attempt + 1
            return peer.peerAddresses[attempt % peer.peerAddresses.count]
        }
        guard let target else { return }
        connect(
            to: .hostPort(host: NWEndpoint.Host(target.host), port: directPort),
            expectedDeviceID: deviceID
        )
    }
}
