import CryptoKit
import Foundation
import Network
import Security
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

extension PeerTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notStarted:
            "The peer network has not started."
        case .peerUnavailable:
            "The selected device is not connected. Wait until it appears online, then try again."
        case let .sendFailed(message):
            "The connection failed while sending data: \(message)"
        case .invalidConfiguration:
            "The trusted peer configuration is invalid."
        case .authenticationFailed:
            "The peer could not authenticate with this workspace. Pair the device again."
        case .replayedFrame:
            "The peer sent an expired or replayed frame."
        }
    }
}

public final class NetworkPeerTransport: PeerTransport, @unchecked Sendable {
    private struct DeferredAnnouncement {
        let deviceID: DeviceID
        let shouldEmitConnected: Bool
        let stabilityToken: UUID
    }

    public static let serviceType = "_unispace._tcp"
    public static let quicServiceType = "_unispace._udp"
    public static let controlPort = NWEndpoint.Port(rawValue: 61_338)!
    public static let realtimePort = NWEndpoint.Port(rawValue: 61_339)!
    public static let crossPlatformQUICPort = NWEndpoint.Port(rawValue: 61_340)!
    public static let crossPlatformPointerPort = NWEndpoint.Port(rawValue: 61_341)!
    private static let quicALPN = "unispace/2"
    private static let crossPlatformQUICALPN = "unispace/3"

    private let queue = DispatchQueue(label: "com.layatai.unispace.network", qos: .userInteractive)
    private let lock = NSLock()
    private let configuredListenPort: NWEndpoint.Port
    private let configuredDirectPort: NWEndpoint.Port
    private let configuredQUICListenPort: NWEndpoint.Port
    private let configuredDirectQUICPort: NWEndpoint.Port
    private let configuredRealtimeListenPort: NWEndpoint.Port
    private let configuredDirectRealtimePort: NWEndpoint.Port
    private let configuredPointerListenPort: NWEndpoint.Port
    private let configuredDirectPointerPort: NWEndpoint.Port
    private let enableBonjour: Bool
    private let enableQUIC: Bool
    private let enableRealtime: Bool
    private let authenticationTimeout: TimeInterval
    private let stream: AsyncStream<PeerEvent>
    private let continuation: AsyncStream<PeerEvent>.Continuation
    private let realtimeInputStream: AsyncStream<PeerEvent>
    private let realtimeInputContinuation: AsyncStream<PeerEvent>.Continuation
    private var localDevice: DeviceDescriptor?
    private var workspaceID: WorkspaceID?
    private var key: Data?
    private var workspaceKeys: [Data] = []
    private var knownPeers: [DeviceID: DeviceDescriptor] = [:]
    private var listener: NWListener?
    private var quicListener: NWListener?
    private var crossPlatformQUICListener: NWListener?
    private var readyControlPort: NWEndpoint.Port?
    private var readyQUICPort: NWEndpoint.Port?
    private var browser: NWBrowser?
    private var quicBrowser: NWBrowser?
    private var connections: [DeviceID: SecurePeerConnection] = [:]
    private var pendingConnections: [ObjectIdentifier: SecurePeerConnection] = [:]
    private var discoveredDevices: [DeviceID: DeviceDescriptor] = [:]
    private var discoveredTCPEndpoints: [DeviceID: NWEndpoint] = [:]
    private var discoveredQUICEndpoints: [DeviceID: NWEndpoint] = [:]
    private var retryAttempts: [DeviceID: Int] = [:]
    private var retryTokens: [DeviceID: UUID] = [:]
    private var outboundPeerIDs = Set<DeviceID>()
    private var desiredRealtimePeerID: DeviceID?
    private var stabilityTokens: [DeviceID: UUID] = [:]
    private var deferredAnnouncements: [ObjectIdentifier: DeferredAnnouncement] = [:]
    private var supersededConnections = Set<ObjectIdentifier>()
    private var realtimeTransport: QUICRealtimeTransport?
    private var authenticatedPointerTransport: AuthenticatedPointerTransport?
    private var running = false

    public init(
        listenPort: NWEndpoint.Port = NetworkPeerTransport.controlPort,
        directPort: NWEndpoint.Port = NetworkPeerTransport.controlPort,
        quicListenPort: NWEndpoint.Port? = nil,
        directQUICPort: NWEndpoint.Port? = nil,
        realtimeListenPort: NWEndpoint.Port = NetworkPeerTransport.realtimePort,
        directRealtimePort: NWEndpoint.Port = NetworkPeerTransport.realtimePort,
        pointerListenPort: NWEndpoint.Port = NetworkPeerTransport.crossPlatformPointerPort,
        directPointerPort: NWEndpoint.Port = NetworkPeerTransport.crossPlatformPointerPort,
        enableBonjour: Bool = true,
        enableQUIC: Bool = true,
        enableRealtime: Bool = true,
        authenticationTimeout: TimeInterval = 8
    ) {
        configuredListenPort = listenPort
        configuredDirectPort = directPort
        configuredQUICListenPort = quicListenPort ?? listenPort
        configuredDirectQUICPort = directQUICPort ?? directPort
        configuredRealtimeListenPort = realtimeListenPort
        configuredDirectRealtimePort = directRealtimePort
        configuredPointerListenPort = pointerListenPort
        configuredDirectPointerPort = directPointerPort
        self.enableBonjour = enableBonjour
        self.enableQUIC = enableQUIC
        self.enableRealtime = enableRealtime
        self.authenticationTimeout = authenticationTimeout
        var captured: AsyncStream<PeerEvent>.Continuation?
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured!
        var capturedRealtimeInput: AsyncStream<PeerEvent>.Continuation?
        self.realtimeInputStream = AsyncStream { capturedRealtimeInput = $0 }
        self.realtimeInputContinuation = capturedRealtimeInput!
    }

    deinit {
        continuation.finish()
        realtimeInputContinuation.finish()
    }

    public func events() -> AsyncStream<PeerEvent> { stream }
    public func realtimeInputEvents() -> AsyncStream<PeerEvent> { realtimeInputStream }

    public var activeControlPort: NWEndpoint.Port? { lock.withLock { readyControlPort } }
    public var activeQUICPort: NWEndpoint.Port? { lock.withLock { readyQUICPort } }

    public func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {
        try await start(localDevice: localDevice, workspace: workspace, workspaceKeys: [key])
    }

    public func start(
        localDevice: DeviceDescriptor,
        workspace: WorkspaceSnapshot,
        workspaceKeys: [Data]
    ) async throws {
        let uniqueKeys = workspaceKeys.reduce(into: [Data]()) { result, candidate in
            if !result.contains(candidate) { result.append(candidate) }
        }
        guard let currentKey = uniqueKeys.first,
              uniqueKeys.allSatisfy({ $0.count >= 32 }) else {
            throw PeerTransportError.invalidConfiguration
        }
        stopSynchronously()
        lock.withLock {
            self.localDevice = localDevice
            workspaceID = workspace.id
            self.key = currentKey
            self.workspaceKeys = uniqueKeys
            knownPeers = Dictionary(
                uniqueKeysWithValues: workspace.devices
                    .filter { $0.id != localDevice.id }
                    .map { ($0.id, $0) }
            )
            running = true
        }

        let parameters = Self.makeParameters()
        let listener = try NWListener(using: parameters, on: configuredListenPort)
        let record = NWTXTRecord([
            "device": localDevice.id.rawValue.uuidString,
            "name": localDevice.name,
            "workspace": workspace.id.rawValue.uuidString,
            "version": String(ControlEnvelope.protocolVersion)
        ])
        if enableBonjour {
            listener.service = NWListener.Service(name: localDevice.name, type: Self.serviceType, txtRecord: record)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            self?.handleListenerState(state, listener: listener)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)

        let quicValues = makeQUICServices(
            localDevice: localDevice,
            workspaceID: workspace.id,
            key: currentKey,
            record: record
        )
        let crossPlatformQUICListener = makeCrossPlatformQUICListener()

        let browser: NWBrowser?
        if enableBonjour {
            let activeBrowser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
            activeBrowser.stateUpdateHandler = { [weak self] state in
                switch state {
                case let .failed(error), let .waiting(error):
                    self?.emit(.failure(nil, error.localizedDescription))
                default:
                    break
                }
            }
            activeBrowser.browseResultsChangedHandler = { [weak self] results, _ in self?.handle(results) }
            activeBrowser.start(queue: queue)
            browser = activeBrowser
        } else {
            browser = nil
        }
        lock.withLock {
            self.listener = listener
            self.browser = browser
            self.quicListener = quicValues.listener
            self.crossPlatformQUICListener = crossPlatformQUICListener
            self.quicBrowser = quicValues.browser
        }
        if enableQUIC, enableRealtime {
            do {
                let realtime = QUICRealtimeTransport(
                    listenPort: configuredRealtimeListenPort,
                    directPort: configuredDirectRealtimePort,
                    enableBonjour: enableBonjour
                )
                realtime.frameHandler = { [weak self] source, frame in
                    self?.emit(.realtimeInput(source, frame))
                }
                try realtime.start(
                    localDevice: localDevice,
                    workspace: workspace,
                    key: currentKey
                )
                let desiredPeer = lock.withLock { () -> DeviceID? in
                    realtimeTransport = realtime
                    return desiredRealtimePeerID
                }
                realtime.setDesiredPeer(desiredPeer, shouldDial: desiredPeer != nil)
            } catch {
                emit(.health(nil, .init(
                    health: .degraded,
                    transport: .quic,
                    detail: "Realtime pointer lane unavailable"
                )))
            }
        }
        if enableRealtime,
           workspace.devices.contains(where: { $0.capabilities.contains(.udpPointerV2) }) {
            do {
                let pointerTransport = AuthenticatedPointerTransport(
                    listenPort: configuredPointerListenPort,
                    directPort: configuredDirectPointerPort
                )
                pointerTransport.frameHandler = { [weak self] source, frame in
                    self?.emit(.realtimeInput(source, PortableInputMapper.map(frame)))
                }
                try pointerTransport.start(localDevice: localDevice, workspace: workspace, key: currentKey)
                lock.withLock { authenticatedPointerTransport = pointerTransport }
            } catch {
                emit(.health(nil, .init(
                    health: .degraded,
                    transport: .tcp,
                    detail: "UDP pointer lane unavailable; using reliable input"
                )))
            }
        }
    }

    public func stop() async { stopSynchronously() }

    public func updateConnectionPolicy(_ policy: PeerConnectionPolicy) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.lock.withLock { () -> ([SecurePeerConnection], [DeviceID]) in
                guard self.running else {
                    self.outboundPeerIDs = policy.outboundPeerIDs
                    return ([], [])
                }
                self.outboundPeerIDs = policy.outboundPeerIDs
                let cancelledIDs = self.retryTokens.keys.filter { !policy.outboundPeerIDs.contains($0) }
                for id in cancelledIDs {
                    self.retryTokens.removeValue(forKey: id)
                    self.retryAttempts.removeValue(forKey: id)
                }
                let pending = self.pendingConnections.filter {
                    guard let expected = $0.value.expectedDeviceID else { return false }
                    return !policy.outboundPeerIDs.contains(expected) && $0.value.isOutbound
                }
                for (objectID, _) in pending {
                    self.pendingConnections.removeValue(forKey: objectID)
                    self.deferredAnnouncements.removeValue(forKey: objectID)
                }
                let staleActive = self.connections.values.filter {
                    $0.isOutbound && $0.deviceID.map {
                        !policy.outboundPeerIDs.contains($0)
                    } == true
                }
                let candidates = policy.outboundPeerIDs.filter { self.connections[$0] == nil }
                return (pending.map(\.value) + staleActive, Array(candidates))
            }
            result.0.forEach { $0.cancel() }
            result.1.forEach { self.scheduleDirectConnection(to: $0, immediately: true) }
        }
    }

    public func setRealtimePeer(_ deviceID: DeviceID?, role: RealtimeConnectionRole) {
        queue.async { [weak self] in
            guard let self else { return }
            let lanes = self.lock.withLock { () -> (QUICRealtimeTransport?, AuthenticatedPointerTransport?, Bool) in
                self.desiredRealtimePeerID = deviceID
                let supportsUDP = deviceID.flatMap { self.knownPeers[$0] }?.capabilities.contains(.udpPointerV2) == true
                return (self.realtimeTransport, self.authenticatedPointerTransport, supportsUDP)
            }
            let shouldDial = role == .dialer
            lanes.1?.setDesiredPeer(deviceID, shouldDial: shouldDial)
            lanes.0?.setDesiredPeer(lanes.2 ? nil : deviceID, shouldDial: shouldDial)
        }
    }

    public func reconnect(to deviceID: DeviceID) {
        queue.async { [weak self] in
            guard let self else { return }
            let pending = self.lock.withLock { () -> [SecurePeerConnection] in
                guard self.running,
                      self.outboundPeerIDs.contains(deviceID),
                      self.connections[deviceID] == nil else { return [] }
                self.retryTokens.removeValue(forKey: deviceID)
                self.retryAttempts[deviceID] = 0
                let matches = self.pendingConnections.filter { $0.value.expectedDeviceID == deviceID }
                for (objectID, _) in matches {
                    self.pendingConnections.removeValue(forKey: objectID)
                    self.deferredAnnouncements.removeValue(forKey: objectID)
                }
                return matches.map(\.value)
            }
            pending.forEach { $0.cancel() }
            self.scheduleDirectConnection(to: deviceID, immediately: true)
        }
    }

    public func reconnectRealtime(to deviceID: DeviceID) {
        lock.withLock { authenticatedPointerTransport }?.reconnect(to: deviceID)
    }

    public func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws {
        let data = try isWindowsPeer(deviceID)
            ? WireFrameCodec.encodePortableControl(envelope)
            : WireFrameCodec.encodeControl(envelope)
        try await send(data: data, to: deviceID)
    }

    public func send(_ frame: InputFrame, to deviceID: DeviceID) async throws {
        if isWindowsPeer(deviceID) {
            guard let portable = PortableInputMapper.map(frame) else { return }
            try await send(data: WireFrameCodec.encodePortableInput(portable), to: deviceID)
        } else {
            try await send(data: WireFrameCodec.encodeInput(frame), to: deviceID)
        }
    }

    @discardableResult
    public func sendRealtime(_ frame: RealtimePointerFrame, to deviceID: DeviceID) async throws -> Bool {
        let supportsUDP = lock.withLock {
            knownPeers[deviceID]?.capabilities.contains(.udpPointerV2) == true
        }
        if supportsUDP,
           let pointerTransport = lock.withLock({ authenticatedPointerTransport }),
           try await pointerTransport.send(PortableInputMapper.map(frame), to: deviceID) {
            return true
        }
        if isWindowsPeer(deviceID) {
            return false
        }
        guard let realtime = lock.withLock({ realtimeTransport }) else {
            return false
        }
        if try await realtime.send(frame, to: deviceID) { return true }
        return false
    }

    public func sendRealtimeImmediately(_ frame: RealtimePointerFrame, to deviceID: DeviceID) -> Bool {
        let lane = lock.withLock { () -> AuthenticatedPointerTransport? in
            guard knownPeers[deviceID]?.capabilities.contains(.udpPointerV2) == true else {
                return nil
            }
            return authenticatedPointerTransport
        }
        return lane?.sendImmediately(PortableInputMapper.map(frame), to: deviceID) == true
    }

    private func send(data: Data, to deviceID: DeviceID) async throws {
        guard let connection = lock.withLock({ connections[deviceID] }) else {
            throw PeerTransportError.peerUnavailable(deviceID)
        }
        try await connection.send(data)
    }

    private func isWindowsPeer(_ deviceID: DeviceID) -> Bool {
        lock.withLock {
            guard let peer = knownPeers[deviceID] else { return false }
            return peer.platform == .windows && peer.capabilities.contains(.crossPlatformInputV2)
        }
    }

    private func stopSynchronously() {
        let values: (NWListener?, NWListener?, NWListener?, NWBrowser?, NWBrowser?, QUICRealtimeTransport?, AuthenticatedPointerTransport?, [SecurePeerConnection]) = lock.withLock {
            let active = Array(connections.values) + Array(pendingConnections.values)
            let values = (listener, quicListener, crossPlatformQUICListener, browser, quicBrowser, realtimeTransport, authenticatedPointerTransport, active)
            listener = nil
            quicListener = nil
            crossPlatformQUICListener = nil
            readyControlPort = nil
            readyQUICPort = nil
            browser = nil
            quicBrowser = nil
            realtimeTransport = nil
            authenticatedPointerTransport = nil
            localDevice = nil
            workspaceID = nil
            key = nil
            workspaceKeys.removeAll()
            connections.removeAll()
            pendingConnections.removeAll()
            discoveredDevices.removeAll()
            discoveredTCPEndpoints.removeAll()
            discoveredQUICEndpoints.removeAll()
            knownPeers.removeAll()
            retryAttempts.removeAll()
            retryTokens.removeAll()
            outboundPeerIDs.removeAll()
            desiredRealtimePeerID = nil
            stabilityTokens.removeAll()
            deferredAnnouncements.removeAll()
            supersededConnections.removeAll()
            running = false
            return values
        }
        values.0?.cancel()
        values.1?.cancel()
        values.2?.cancel()
        values.3?.cancel()
        values.4?.cancel()
        values.5?.stop()
        values.6?.stop()
        values.7.forEach { $0.cancel() }
    }

    private func makeCrossPlatformQUICListener() -> NWListener? {
        guard enableQUIC,
              lock.withLock({ knownPeers.values.contains(where: {
                  $0.platform == .windows && $0.capabilities.contains(.quicStreamV2)
              }) }) else { return nil }
        do {
            let listener = try NWListener(
                using: try Self.makeCrossPlatformQUICParameters(),
                on: Self.crossPlatformQUICPort
            )
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, transport: .quic)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case let .failed(error), let .waiting(error):
                    self?.emit(.health(nil, .init(
                        health: .degraded,
                        transport: .quic,
                        detail: "Windows QUIC unavailable: \(error.localizedDescription)"
                    )))
                default:
                    break
                }
            }
            listener.start(queue: queue)
            return listener
        } catch {
            emit(.health(nil, .init(
                health: .degraded,
                transport: .quic,
                detail: "Windows QUIC unavailable; using TCP"
            )))
            return nil
        }
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener?) {
        switch state {
        case .ready:
            if let port = listener?.port { lock.withLock { readyControlPort = port } }
        case let .failed(error), let .waiting(error): emit(.failure(nil, error.localizedDescription))
        default: break
        }
    }

    private func makeQUICServices(
        localDevice: DeviceDescriptor,
        workspaceID: WorkspaceID,
        key: Data,
        record: NWTXTRecord
    ) -> (listener: NWListener?, browser: NWBrowser?) {
        guard enableQUIC else { return (nil, nil) }
        do {
            let parameters = try Self.makeQUICParameters(workspaceID: workspaceID, key: key)
            let listener = try NWListener(using: parameters, on: configuredQUICListenPort)
            if enableBonjour {
                listener.service = NWListener.Service(
                    name: localDevice.name,
                    type: Self.quicServiceType,
                    txtRecord: record
                )
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    if let port = listener?.port { self?.lock.withLock { self?.readyQUICPort = port } }
                case let .failed(error):
                    self?.emit(.failure(nil, "QUIC listener: \(error.localizedDescription)"))
                case let .waiting(error):
                    self?.emit(.health(nil, .init(
                        health: .degraded,
                        transport: .quic,
                        detail: error.localizedDescription
                    )))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, transport: .quic)
            }
            listener.start(queue: queue)

            let browser: NWBrowser?
            if enableBonjour {
                let activeBrowser = NWBrowser(
                    for: .bonjour(type: Self.quicServiceType, domain: nil),
                    using: parameters
                )
                activeBrowser.stateUpdateHandler = { [weak self] state in
                    if case let .failed(error) = state {
                        self?.emit(.failure(nil, "QUIC discovery: \(error.localizedDescription)"))
                    }
                }
                activeBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                    self?.handleQUIC(results)
                }
                activeBrowser.start(queue: queue)
                browser = activeBrowser
            } else {
                browser = nil
            }
            return (listener, browser)
        } catch {
            emit(.health(nil, .init(
                health: .degraded,
                transport: .quic,
                detail: "QUIC unavailable; using TCP"
            )))
            return (nil, nil)
        }
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        lock.lock()
        guard let localDevice, let workspaceID else { lock.unlock(); return }
        let previous = Set(discoveredDevices.keys)
        var current: [DeviceID: DeviceDescriptor] = [:]
        var currentEndpoints: [DeviceID: NWEndpoint] = [:]
        var candidates: [(DeviceDescriptor, NWEndpoint)] = []
        for result in results {
            guard case let .bonjour(record) = result.metadata,
                  record["workspace"] == workspaceID.rawValue.uuidString,
                  let deviceString = record["device"], let uuid = UUID(uuidString: deviceString) else { continue }
            let id = DeviceID(rawValue: uuid)
            guard id != localDevice.id else { continue }
            let device = DeviceDescriptor(id: id, name: record["name"] ?? "Mac")
            current[id] = device
            currentEndpoints[id] = result.endpoint
            if outboundPeerIDs.contains(id), connections[id] == nil,
               !pendingConnections.values.contains(where: { $0.expectedDeviceID == id }) {
                candidates.append((device, result.endpoint))
            }
        }
        discoveredDevices = current
        discoveredTCPEndpoints = currentEndpoints
        let added = Set(current.keys).subtracting(previous)
        let removed = previous.subtracting(current.keys)
        lock.unlock()

        for id in added { if let descriptor = current[id] { emit(.discovered(descriptor)) } }
        for id in removed { emit(.lost(id)) }
        for (device, endpoint) in candidates {
            connect(to: endpoint, expectedDevice: device, isOutbound: true, transport: .tcp)
        }
    }

    private func handleQUIC(_ results: Set<NWBrowser.Result>) {
        let candidates = lock.withLock { () -> [(DeviceDescriptor, NWEndpoint)] in
            guard let localDevice, let workspaceID else { return [] }
            var currentEndpoints: [DeviceID: NWEndpoint] = [:]
            let candidates = results.compactMap { result -> (DeviceDescriptor, NWEndpoint)? in
                guard case let .bonjour(record) = result.metadata,
                      record["workspace"] == workspaceID.rawValue.uuidString,
                      let deviceString = record["device"],
                      let uuid = UUID(uuidString: deviceString) else { return nil }
                let id = DeviceID(rawValue: uuid)
                currentEndpoints[id] = result.endpoint
                guard id != localDevice.id,
                      outboundPeerIDs.contains(id),
                      connections[id]?.transportKind != .quic,
                      !pendingConnections.values.contains(where: {
                          $0.expectedDeviceID == id && $0.transportKind == .quic
                      }) else { return nil }
                return (DeviceDescriptor(id: id, name: record["name"] ?? "Mac"), result.endpoint)
            }
            discoveredQUICEndpoints = currentEndpoints
            return candidates
        }
        for (device, endpoint) in candidates {
            connect(to: endpoint, expectedDevice: device, isOutbound: true, transport: .quic)
        }
    }

    private func connect(
        to endpoint: NWEndpoint,
        expectedDevice: DeviceDescriptor,
        isOutbound: Bool,
        transport: TransportKind
    ) {
        let parameters: NWParameters
        switch transport {
        case .tcp:
            parameters = Self.makeParameters()
        case .quic:
            guard let configuration = lock.withLock({ workspaceID.flatMap { id in key.map { (id, $0) } } }) else {
                return
            }
            do {
                parameters = try Self.makeQUICParameters(
                    workspaceID: configuration.0,
                    key: configuration.1
                )
            } catch {
                emit(.health(expectedDevice.id, .init(
                    health: .degraded,
                    transport: .quic,
                    detail: "QUIC unavailable; using TCP"
                )))
                return
            }
        }
        emit(.health(expectedDevice.id, .init(health: .connecting, transport: transport)))
        let connection = NWConnection(to: endpoint, using: parameters)
        install(
            connection,
            expectedDeviceID: expectedDevice.id,
            isOutbound: isOutbound,
            transport: transport
        )
        connection.start(queue: queue)
    }

    private func accept(_ connection: NWConnection, transport: TransportKind = .tcp) {
        install(connection, expectedDeviceID: nil, isOutbound: false, transport: transport)
        connection.start(queue: queue)
    }

    private func install(
        _ connection: NWConnection,
        expectedDeviceID: DeviceID?,
        isOutbound: Bool,
        transport: TransportKind
    ) {
        let configuration = lock.withLock { () -> (DeviceID, WorkspaceID, [Data])? in
            guard let localDevice, let workspaceID, !workspaceKeys.isEmpty else { return nil }
            return (localDevice.id, workspaceID, workspaceKeys)
        }
        guard let configuration else { connection.cancel(); return }
        let managed = SecurePeerConnection(
            connection: connection,
            localDeviceID: configuration.0,
            workspaceID: configuration.1,
            workspaceKeys: configuration.2,
            expectedDeviceID: expectedDeviceID,
            isOutbound: isOutbound,
            transportKind: transport,
            authenticationTimeout: authenticationTimeout
        )
        let objectID = ObjectIdentifier(managed)
        lock.withLock { pendingConnections[objectID] = managed }
        managed.stateHandler = { [weak self, weak managed] state in
            guard let self, let managed else { return }
            self.handleConnectionState(state, managed: managed, objectID: objectID, expectedDeviceID: expectedDeviceID)
        }
        managed.authenticatedHandler = { [weak self, weak managed] deviceID in
            guard let self, let managed else { return }
            let isKnownPeer = self.lock.withLock { self.knownPeers[deviceID] != nil }
            if managed.authenticatedWithPreviousWorkspaceKey && !isKnownPeer {
                managed.cancel()
                return
            }
            // The dialer speaks first at the application layer. Waiting on every
            // accepted connection lets the peer's hello select the wire codec,
            // even when persisted platform metadata is stale or incomplete.
            let deferUntilHello = !managed.isOutbound
            self.register(
                managed,
                as: deviceID,
                objectID: objectID,
                deferAnnouncement: deferUntilHello
            )
            if !deferUntilHello { self.sendApplicationHello(to: managed, deviceID: deviceID) }
        }
        managed.frameHandler = { [weak self, weak managed] kind, payload in
            guard let self, let managed else { return }
            self.handleFrame(kind: kind, payload: payload, managed: managed)
        }
        managed.viabilityHandler = { [weak self, weak managed] viable in
            guard let self, let managed, let deviceID = managed.deviceID else { return }
            self.emit(.health(deviceID, .init(
                health: viable ? .healthy : .degraded,
                transport: managed.transportKind,
                detail: viable ? nil : "Network path is temporarily not viable"
            )))
        }
        managed.betterPathHandler = { [weak self, weak managed] available in
            guard available, let self, let managed, let deviceID = managed.deviceID else { return }
            self.emit(.health(deviceID, .init(
                health: .degraded,
                transport: managed.transportKind,
                detail: "A better network path is available"
            )))
        }
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        managed: SecurePeerConnection,
        objectID: ObjectIdentifier,
        expectedDeviceID: DeviceID?
    ) {
        switch state {
        case let .waiting(error):
            emit(.health(managed.deviceID ?? expectedDeviceID, .init(
                health: .degraded,
                transport: managed.transportKind,
                detail: error.localizedDescription
            )))
        case let .failed(error):
            remove(
                managed,
                objectID: objectID,
                expectedDeviceID: expectedDeviceID,
                failureDetail: error.localizedDescription
            )
        case .cancelled:
            remove(managed, objectID: objectID, expectedDeviceID: expectedDeviceID)
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
                try handleControl(envelope, from: deviceID, managed: managed)
            case .inputBinary:
                let frame = try WireFrameCodec.decodeInput(payload)
                guard frame.controllerID == deviceID else { throw ControlProtocolError.malformedFrame }
                emit(.input(deviceID, frame))
            case .realtimePointerBinary:
                throw ControlProtocolError.malformedFrame
            case .controlJSONV2:
                let envelope = try WireFrameCodec.decodePortableControl(payload)
                try handleControl(envelope, from: deviceID, managed: managed)
            case .inputBinaryV2, .realtimePointerBinaryV2:
                // Windows peers are receiver-only. Portable input received by a Mac is invalid.
                throw ControlProtocolError.malformedFrame
            }
        } catch {
            emit(.failure(managed.deviceID, String(describing: error)))
            managed.cancel()
        }
    }

    private func handleControl(
        _ envelope: ControlEnvelope,
        from deviceID: DeviceID,
        managed: SecurePeerConnection
    ) throws {
        if case let .hello(device) = envelope.message {
            guard device.id == deviceID else { throw PeerTransportError.authenticationFailed }
            lock.withLock {
                knownPeers[device.id] = knownPeers[device.id].map {
                    WorkspaceReplicaMerger.mergeDevice(
                        $0,
                        with: device,
                        capabilitiesAreAuthoritative: true
                    )
                } ?? device
            }
        }
        emit(.control(deviceID, envelope))
        if case .hello = envelope.message {
            completeDeferredHandshake(managed: managed, deviceID: deviceID)
        }
    }

    private func sendApplicationHello(to managed: SecurePeerConnection, deviceID: DeviceID) {
        let hello = lock.withLock { localDevice.map { ControlEnvelope(message: .hello($0)) } }
        guard let hello else { return }
        let data = try? (isWindowsPeer(deviceID)
            ? WireFrameCodec.encodePortableControl(hello)
            : WireFrameCodec.encodeControl(hello))
        if let data { managed.send(data, completion: nil) }
    }

    private func completeDeferredHandshake(managed: SecurePeerConnection, deviceID: DeviceID) {
        let objectID = ObjectIdentifier(managed)
        let announcement = lock.withLock { () -> DeferredAnnouncement? in
            guard let announcement = deferredAnnouncements[objectID],
                  announcement.deviceID == deviceID,
                  connections[deviceID] === managed else { return nil }
            deferredAnnouncements.removeValue(forKey: objectID)
            return announcement
        }
        guard let announcement else { return }
        sendApplicationHello(to: managed, deviceID: deviceID)
        scheduleAnnouncement(
            managed: managed,
            deviceID: deviceID,
            shouldEmitConnected: announcement.shouldEmitConnected,
            stabilityToken: announcement.stabilityToken
        )
    }

    private func register(
        _ managed: SecurePeerConnection,
        as deviceID: DeviceID,
        objectID: ObjectIdentifier,
        deferAnnouncement: Bool
    ) {
        var replaced: SecurePeerConnection?
        var rejected = false
        var shouldEmitConnected = false
        lock.lock()
        pendingConnections.removeValue(forKey: objectID)
        if let existing = connections[deviceID], existing !== managed {
            if shouldReplace(existing, with: managed, for: deviceID) {
                connections[deviceID] = managed
                replaced = existing
            } else {
                rejected = true
            }
        } else {
            shouldEmitConnected = connections[deviceID] == nil
            connections[deviceID] = managed
        }
        retryTokens.removeValue(forKey: deviceID)
        let stabilityToken = UUID()
        stabilityTokens[deviceID] = stabilityToken
        lock.unlock()
        if rejected {
            managed.cancel()
            return
        }
        replaced?.cancel()
        if deferAnnouncement {
            lock.withLock {
                deferredAnnouncements[objectID] = DeferredAnnouncement(
                    deviceID: deviceID,
                    shouldEmitConnected: shouldEmitConnected,
                    stabilityToken: stabilityToken
                )
            }
            queue.asyncAfter(deadline: .now() + authenticationTimeout) { [weak self, weak managed] in
                guard let self, let managed else { return }
                let timedOut = self.lock.withLock {
                    self.deferredAnnouncements.removeValue(forKey: objectID) != nil
                        && self.connections[deviceID] === managed
                }
                if timedOut { managed.cancel() }
            }
        } else {
            scheduleAnnouncement(
                managed: managed,
                deviceID: deviceID,
                shouldEmitConnected: shouldEmitConnected,
                stabilityToken: stabilityToken
            )
        }
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak managed] in
            guard let self, let managed else { return }
            self.lock.withLock {
                guard self.stabilityTokens[deviceID] == stabilityToken,
                      self.connections[deviceID] === managed else { return }
                self.retryAttempts[deviceID] = 0
            }
        }
    }

    private func scheduleAnnouncement(
        managed: SecurePeerConnection,
        deviceID: DeviceID,
        shouldEmitConnected: Bool,
        stabilityToken: UUID
    ) {
        let announcementDelay: TimeInterval = managed.transportKind == .quic ? 0.15 : 0
        queue.asyncAfter(deadline: .now() + announcementDelay) { [weak self, weak managed] in
            guard let self, let managed else { return }
            let isCurrent = self.lock.withLock {
                self.stabilityTokens[deviceID] == stabilityToken &&
                    self.connections[deviceID] === managed
            }
            guard isCurrent else { return }
            self.emit(.health(deviceID, .init(health: .healthy, transport: managed.transportKind)))
            if shouldEmitConnected { self.emit(.connected(deviceID)) }
            if managed.authenticatedWithPreviousWorkspaceKey {
                self.emit(.workspaceUpgradeRequired(deviceID))
            }
        }
    }

    private func remove(
        _ managed: SecurePeerConnection,
        objectID: ObjectIdentifier,
        expectedDeviceID: DeviceID?,
        failureDetail: String? = nil
    ) {
        var removedActive = false
        var wasSuperseded = false
        var retryDeviceID: DeviceID?
        var shouldRetry = false
        lock.lock()
        wasSuperseded = supersededConnections.remove(objectID) != nil
        pendingConnections.removeValue(forKey: objectID)
        deferredAnnouncements.removeValue(forKey: objectID)
        let deviceID = managed.deviceID
        if let deviceID, connections[deviceID] === managed {
            connections.removeValue(forKey: deviceID)
            stabilityTokens.removeValue(forKey: deviceID)
            removedActive = true
        }
        let candidateID = deviceID ?? expectedDeviceID
        if removedActive || deviceID == nil && candidateID.flatMap({ connections[$0] }) == nil {
            retryDeviceID = candidateID
        }
        if let retryDeviceID {
            shouldRetry = running &&
                outboundPeerIDs.contains(retryDeviceID) &&
                Self.hasReconnectRoute(
                    peer: knownPeers[retryDeviceID],
                    discoveredPeer: discoveredDevices[retryDeviceID],
                    tcpEndpoint: discoveredTCPEndpoints[retryDeviceID],
                    quicEndpoint: discoveredQUICEndpoints[retryDeviceID]
                )
        }
        lock.unlock()
        guard !wasSuperseded else { return }
        if let retryDeviceID {
            emit(.health(retryDeviceID, .init(
                health: shouldRetry ? .reconnecting : .disconnected,
                transport: managed.transportKind,
                detail: failureDetail
            )))
        }
        if let deviceID, removedActive {
            emit(.disconnected(deviceID))
        }
        if shouldRetry, let retryDeviceID {
            scheduleDirectConnection(to: retryDeviceID, immediately: false)
        }
    }

    private func shouldReplace(
        _ existing: SecurePeerConnection,
        with candidate: SecurePeerConnection,
        for peerID: DeviceID
    ) -> Bool {
        if existing.transportKind != candidate.transportKind {
            return candidate.transportKind == .quic
        }
        guard let localID = localDevice?.id else { return false }
        let preferredOutbound = localID < peerID
        return candidate.isOutbound == preferredOutbound && existing.isOutbound != preferredOutbound
    }

    private func scheduleDirectConnection(to deviceID: DeviceID, immediately: Bool) {
        let schedule = lock.withLock { () -> (UUID, TimeInterval)? in
            guard running, connections[deviceID] == nil,
                  outboundPeerIDs.contains(deviceID),
                  retryTokens[deviceID] == nil,
                  Self.hasReconnectRoute(
                    peer: knownPeers[deviceID],
                    discoveredPeer: discoveredDevices[deviceID],
                    tcpEndpoint: discoveredTCPEndpoints[deviceID],
                    quicEndpoint: discoveredQUICEndpoints[deviceID]
                  ) else { return nil }
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

    static func hasReconnectRoute(
        peer: DeviceDescriptor?,
        discoveredPeer: DeviceDescriptor?,
        tcpEndpoint: NWEndpoint?,
        quicEndpoint: NWEndpoint?
    ) -> Bool {
        let knownDevice = peer ?? discoveredPeer
        guard let knownDevice else { return false }
        return !knownDevice.peerAddresses.isEmpty || tcpEndpoint != nil || quicEndpoint != nil
    }

    private func attemptDirectConnection(to deviceID: DeviceID, token: UUID) {
        let target = lock.withLock { () -> (DeviceDescriptor, PeerAddress?, NWEndpoint?, NWEndpoint?)? in
            guard running, retryTokens[deviceID] == token,
                  connections[deviceID] == nil,
                  !pendingConnections.values.contains(where: { $0.expectedDeviceID == deviceID }),
                  let peer = knownPeers[deviceID] ?? discoveredDevices[deviceID] else {
                retryTokens.removeValue(forKey: deviceID)
                return nil
            }
            retryTokens.removeValue(forKey: deviceID)
            let attempt = retryAttempts[deviceID, default: 0]
            retryAttempts[deviceID] = attempt + 1
            let address = peer.peerAddresses.isEmpty ? nil : peer.peerAddresses[attempt % peer.peerAddresses.count]
            let tcpEndpoint = discoveredTCPEndpoints[deviceID]
            let quicEndpoint = discoveredQUICEndpoints[deviceID]
            guard address != nil || tcpEndpoint != nil || quicEndpoint != nil else { return nil }
            return (peer, address, tcpEndpoint, quicEndpoint)
        }
        guard let (peer, address, tcpEndpoint, quicEndpoint) = target else { return }
        if enableQUIC, let endpoint = quicEndpoint ?? address.map({
            NWEndpoint.hostPort(host: NWEndpoint.Host($0.host), port: configuredDirectQUICPort)
        }) {
            connect(to: endpoint, expectedDevice: peer, isOutbound: true, transport: .quic)
            queue.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.transitionToTCPFallback(to: peer, endpoint: tcpEndpoint ?? address.map({
                    NWEndpoint.hostPort(host: NWEndpoint.Host($0.host), port: self?.configuredDirectPort ?? Self.controlPort)
                }))
            }
        } else if let address {
            attemptTCPFallback(to: peer, address: address)
        } else if let tcpEndpoint {
            attemptTCPFallback(to: peer, endpoint: tcpEndpoint)
        }
    }

    private func attemptTCPFallback(to peer: DeviceDescriptor, address: PeerAddress) {
        attemptTCPFallback(
            to: peer,
            endpoint: .hostPort(host: NWEndpoint.Host(address.host), port: configuredDirectPort)
        )
    }

    private func transitionToTCPFallback(to peer: DeviceDescriptor, endpoint: NWEndpoint?) {
        let superseded = lock.withLock { () -> [SecurePeerConnection] in
            guard running, connections[peer.id] == nil else { return [] }
            let matches = pendingConnections.filter {
                $0.value.expectedDeviceID == peer.id && $0.value.transportKind == .quic
            }
            supersededConnections.formUnion(matches.keys)
            return matches.map(\.value)
        }
        superseded.forEach { $0.cancel() }
        attemptTCPFallback(to: peer, endpoint: endpoint)
    }

    private func attemptTCPFallback(to peer: DeviceDescriptor, endpoint: NWEndpoint?) {
        guard let endpoint else { return }
        let shouldConnect = lock.withLock {
            running && connections[peer.id] == nil &&
                !pendingConnections.values.contains(where: {
                    $0.expectedDeviceID == peer.id && $0.transportKind == .tcp
                })
        }
        guard shouldConnect else { return }
        connect(to: endpoint, expectedDevice: peer, isOutbound: true, transport: .tcp)
    }

    private func emit(_ event: PeerEvent) {
        continuation.yield(event)
        if case .realtimeInput = event {
            realtimeInputContinuation.yield(event)
        }
    }

    static func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    static func makeQUICParameters(
        workspaceID: WorkspaceID,
        key: Data,
        isDatagram: Bool = false
    ) throws -> NWParameters {
        let options = NWProtocolQUIC.Options(alpn: [quicALPN])
        options.isDatagram = isDatagram
        if isDatagram { options.maxDatagramFrameSize = 1_200 }
        options.idleTimeout = 30_000
        options.maxUDPPayloadSize = 1_350
        let localIdentity = try QUICIdentityProvider.identity()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, localIdentity)

        // The certificate only bootstraps TLS for local QUIC. Peer authentication and
        // channel confidentiality are enforced by the workspace-key HMAC/AEAD handshake.
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue.global(qos: .userInteractive)
        )
        let identityData = Data("unispace:\(workspaceID.rawValue.uuidString):v2".utf8)
        let psk = key.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            DispatchData(bytes: bytes) as dispatch_data_t
        }
        let identity = identityData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            DispatchData(bytes: bytes) as dispatch_data_t
        }
        sec_protocol_options_add_pre_shared_key(options.securityProtocolOptions, psk, identity)
        sec_protocol_options_set_tls_pre_shared_key_identity_hint(
            options.securityProtocolOptions,
            identity
        )
        sec_protocol_options_set_pre_shared_key_selection_block(
            options.securityProtocolOptions,
            { _, _, complete in complete(identity) },
            DispatchQueue.global(qos: .userInteractive)
        )
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        let parameters = NWParameters(quic: options)
        parameters.includePeerToPeer = true
        return parameters
    }

    static func makeCrossPlatformQUICParameters() throws -> NWParameters {
        let options = NWProtocolQUIC.Options(alpn: [crossPlatformQUICALPN])
        options.idleTimeout = 30_000
        options.maxUDPPayloadSize = 1_350
        sec_protocol_options_set_local_identity(
            options.securityProtocolOptions,
            try QUICIdentityProvider.identity()
        )
        // TLS bootstraps QUIC. The workspace-key secure hello and AEAD channel
        // below authenticate the peer and protect application frames.
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue.global(qos: .userInteractive)
        )
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        let parameters = NWParameters(quic: options)
        parameters.includePeerToPeer = true
        return parameters
    }
}

private enum SecurePacketKind: UInt8 {
    case hello = 10
    case sealed = 11
}

enum SecureChannelSecurityProfile: Equatable {
    case reliableV1
    case pointerV2

    var helloVersion: UInt16 { self == .reliableV1 ? 1 : 2 }
    var helloPrefix: String { self == .reliableV1 ? "UniSpace secure hello v1" : "UniSpace pointer hello v2" }
    var infoPrefix: String { self == .reliableV1 ? "UniSpace channel v1" : "UniSpace pointer lane v2" }
}

struct SecureChannelHello: Codable, Sendable {
    let version: UInt16
    let workspaceID: WorkspaceID
    let deviceID: DeviceID
    let nonce: Data
    let proof: Data
    let supportedWireVersions: [UInt16]

    private enum CodingKeys: String, CodingKey {
        case version, workspaceID, deviceID, nonce, proof, supportedWireVersions
    }

    init(
        version: UInt16,
        workspaceID: WorkspaceID,
        deviceID: DeviceID,
        nonce: Data,
        proof: Data,
        supportedWireVersions: [UInt16] = [1, 2]
    ) {
        self.version = version
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.nonce = nonce
        self.proof = proof
        self.supportedWireVersions = supportedWireVersions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt16.self, forKey: .version)
        workspaceID = try container.decodeUUIDIdentifier(WorkspaceID.self, forKey: .workspaceID)
        deviceID = try container.decodeUUIDIdentifier(DeviceID.self, forKey: .deviceID)
        nonce = try container.decode(Data.self, forKey: .nonce)
        proof = try container.decode(Data.self, forKey: .proof)
        supportedWireVersions = try container.decodeIfPresent([UInt16].self, forKey: .supportedWireVersions) ?? [1]
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeUUIDIdentifier(workspaceID, forKey: .workspaceID)
        try container.encodeUUIDIdentifier(deviceID, forKey: .deviceID)
        try container.encode(nonce, forKey: .nonce)
        try container.encode(proof, forKey: .proof)
        try container.encode(supportedWireVersions, forKey: .supportedWireVersions)
    }
}

final class SecurePeerConnection: @unchecked Sendable {
    let connection: NWConnection
    let expectedDeviceID: DeviceID?
    let isOutbound: Bool
    let transportKind: TransportKind
    let isDatagram: Bool
    var stateHandler: (@Sendable (NWConnection.State) -> Void)?
    var authenticatedHandler: (@Sendable (DeviceID) -> Void)?
    var frameHandler: (@Sendable (WireFrameKind, Data) -> Void)?
    var viabilityHandler: (@Sendable (Bool) -> Void)?
    var betterPathHandler: (@Sendable (Bool) -> Void)?

    private let localDeviceID: DeviceID
    private let workspaceID: WorkspaceID
    private let workspaceKeys: [SymmetricKey]
    private let localNonce: Data
    private let securityProfile: SecureChannelSecurityProfile
    private let lock = NSLock()
    private let sendQueue = DispatchQueue(
        label: "com.layatai.unispace.secure-peer-send",
        qos: .userInteractive
    )
    private var buffer = Data()
    private var sessionKey: SymmetricKey?
    private var authenticatedDeviceID: DeviceID?
    private var authenticatedKeyIndex: Int?
    private var outboundSequence: UInt64 = 0
    private var inboundSequence: UInt64?

    var deviceID: DeviceID? { lock.withLock { authenticatedDeviceID } }
    var authenticatedWithPreviousWorkspaceKey: Bool {
        lock.withLock { (authenticatedKeyIndex ?? 0) > 0 }
    }

    convenience init(
        connection: NWConnection,
        localDeviceID: DeviceID,
        workspaceID: WorkspaceID,
        workspaceKey: Data,
        expectedDeviceID: DeviceID?,
        isOutbound: Bool = false,
        transportKind: TransportKind = .tcp,
        isDatagram: Bool = false,
        securityProfile: SecureChannelSecurityProfile = .reliableV1,
        authenticationTimeout: TimeInterval = 8
    ) {
        self.init(
            connection: connection,
            localDeviceID: localDeviceID,
            workspaceID: workspaceID,
            workspaceKeys: [workspaceKey],
            expectedDeviceID: expectedDeviceID,
            isOutbound: isOutbound,
            transportKind: transportKind,
            isDatagram: isDatagram,
            securityProfile: securityProfile,
            authenticationTimeout: authenticationTimeout
        )
    }

    init(
        connection: NWConnection,
        localDeviceID: DeviceID,
        workspaceID: WorkspaceID,
        workspaceKeys: [Data],
        expectedDeviceID: DeviceID?,
        isOutbound: Bool = false,
        transportKind: TransportKind = .tcp,
        isDatagram: Bool = false,
        securityProfile: SecureChannelSecurityProfile = .reliableV1,
        authenticationTimeout: TimeInterval = 8
    ) {
        precondition(!workspaceKeys.isEmpty)
        self.connection = connection
        self.localDeviceID = localDeviceID
        self.workspaceID = workspaceID
        self.workspaceKeys = workspaceKeys.map { SymmetricKey(data: $0) }
        self.expectedDeviceID = expectedDeviceID
        self.isOutbound = isOutbound
        self.transportKind = transportKind
        self.isDatagram = isDatagram
        self.localNonce = PairingCryptoSession.randomData(count: 32)
        self.securityProfile = securityProfile
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateHandler?(state)
            if case .ready = state {
                self?.receiveNext()
                self?.sendHello()
            }
        }
        connection.viabilityUpdateHandler = { [weak self] viable in
            self?.viabilityHandler?(viable)
        }
        connection.betterPathUpdateHandler = { [weak self] available in
            self?.betterPathHandler?(available)
        }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + authenticationTimeout) { [weak self] in
            guard let self, self.deviceID == nil else { return }
            self.cancel()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(data) { [weak self] error in
                if let error {
                    self?.cancel()
                    continuation.resume(throwing: PeerTransportError.sendFailed(error.localizedDescription))
                }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func send(_ data: Data, completion: (@Sendable (NWError?) -> Void)?) {
        sendQueue.async { [self] in
            do {
                let outer = try seal(data)
                connection.send(
                    content: outer,
                    contentContext: isDatagram ? .defaultMessage : .defaultStream,
                    isComplete: isDatagram,
                    completion: .contentProcessed { error in completion?(error) }
                )
            } catch {
                completion?(NWError.posix(.EAUTH))
                cancel()
            }
        }
    }

    func cancel() { connection.cancel() }

    private func sendHello() {
        let unsigned = helloProofPayload(deviceID: localDeviceID, nonce: localNonce)
        for workspaceKey in workspaceKeys {
            let proof = Data(HMAC<SHA256>.authenticationCode(for: unsigned, using: workspaceKey))
            let hello = SecureChannelHello(
                version: securityProfile.helloVersion,
                workspaceID: workspaceID,
                deviceID: localDeviceID,
                nonce: localNonce,
                proof: proof
            )
            guard let payload = try? JSONEncoder().encode(hello) else { cancel(); return }
            connection.send(
                content: Self.outerFrame(kind: .hello, payload: payload),
                contentContext: isDatagram ? .defaultMessage : .defaultStream,
                isComplete: isDatagram,
                completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.cancel() }
                }
            )
        }
        if isDatagram {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.deviceID == nil else { return }
                self.sendHello()
            }
        }
    }

    private func handleHello(_ payload: Data) throws {
        let hello = try JSONDecoder().decode(SecureChannelHello.self, from: payload)
        guard hello.version == securityProfile.helloVersion, hello.workspaceID == workspaceID,
              expectedDeviceID == nil || expectedDeviceID == hello.deviceID else {
            throw PeerTransportError.authenticationFailed
        }
        if lock.withLock({ sessionKey != nil }) { return }
        let proofPayload = helloProofPayload(deviceID: hello.deviceID, nonce: hello.nonce)
        guard let keyIndex = workspaceKeys.firstIndex(where: {
            HMAC<SHA256>.isValidAuthenticationCode(
                hello.proof,
                authenticating: proofPayload,
                using: $0
            )
        }) else {
            throw PeerTransportError.authenticationFailed
        }
        let workspaceKey = workspaceKeys[keyIndex]
        let localFirst = localDeviceID < hello.deviceID
        let derived = Self.deriveSessionKey(
            workspaceID: workspaceID,
            workspaceKey: workspaceKey,
            firstNonce: localFirst ? localNonce : hello.nonce,
            secondNonce: localFirst ? hello.nonce : localNonce,
            securityProfile: securityProfile
        )
        let shouldNotify = lock.withLock { () -> Bool in
            guard sessionKey == nil else { return false }
            sessionKey = derived
            authenticatedDeviceID = hello.deviceID
            authenticatedKeyIndex = keyIndex
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

    static func deriveSessionKey(
        workspaceID: WorkspaceID,
        workspaceKey: SymmetricKey,
        firstNonce: Data,
        secondNonce: Data,
        securityProfile: SecureChannelSecurityProfile
    ) -> SymmetricKey {
        let salt = firstNonce + secondNonce
        let info = Data("\(securityProfile.infoPrefix)|\(workspaceID.rawValue.uuidString)".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: workspaceKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    static func sealForInterop(
        _ plaintext: Data,
        key: SymmetricKey,
        nonce: Data
    ) throws -> Data {
        try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: try ChaChaPoly.Nonce(data: nonce)
        ).combined
    }

    private func helloProofPayload(deviceID: DeviceID, nonce: Data) -> Data {
        var data = Data(securityProfile.helloPrefix.utf8)
        data.append(Data(workspaceID.rawValue.uuidString.utf8))
        data.append(Data(deviceID.rawValue.uuidString.utf8))
        data.append(nonce)
        return data
    }

    private func receiveNext() {
        if isDatagram {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data, !data.isEmpty { self.consume(data) }
                if error == nil { self.receiveNext() } else { self.cancel() }
            }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
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

        for (kind, payload) in packets {
            do {
                switch kind {
                case .hello:
                    try handleHello(payload)
                case .sealed:
                    let inner = try open(payload)
                    let decoded = try WireFrameCodec.decode(inner)
                    frameHandler?(decoded.0, decoded.1)
                }
            } catch PeerTransportError.replayedFrame where isDatagram {
                // Reordering is normal for QUIC DATAGRAM. Authentication succeeded,
                // so silently discard an older packet without tearing down the lane.
                continue
            } catch PeerTransportError.authenticationFailed where kind == .hello && deviceID == nil {
                // A peer can advertise several bounded workspace-key candidates.
                // Ignore a non-matching proof until another hello succeeds or the
                // authentication timeout closes the connection.
                continue
            } catch {
                cancel()
                return
            }
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
