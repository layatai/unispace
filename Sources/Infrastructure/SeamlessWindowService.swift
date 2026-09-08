import AppKit
import Network
import UniSpaceApplication
import UniSpaceDomain

/// macOS composition of the platform-neutral lease with capture, authenticated
/// lanes and native windows. One presentation per Mac bounds encoder/GPU use.
@MainActor
public final class SeamlessWindowService {
    public private(set) var status = "Window sharing is off"
    public private(set) var incoming: (WindowPresentationLease, SeamlessWindowDescriptor)?
    public private(set) var availablePeers = Set<DeviceID>()
    public private(set) var remoteCatalog: (peer: DeviceID, windows: [SeamlessWindowDescriptor])?
    private var pendingCatalogRequest: DeviceID?
    public var onChange: (() -> Void)?
    public var isPresenting: Bool { state.phase != .idle || captureTask != nil }
    private let capture: any SeamlessCaptureSource
    private var state = WindowPresentationState()
    private var input: (any SeamlessInputTarget)?
    private var proxy: SeamlessWindowProxy?
    private var configuration: (workspace: WorkspaceSnapshot, local: DeviceID, key: Data)?
    private var listeners: [NWListener] = []
    private var browser: NWBrowser?
    private var endpoints: [DeviceID: NWEndpoint] = [:]
    private var connections: [UUID: SeamlessWindowConnection] = [:]
    private var control: SeamlessWindowConnection?
    private var video: SeamlessWindowConnection?
    private var descriptor: SeamlessWindowDescriptor?
    private var offerSent = false
    private var acceptanceRequested = false
    private var visible = true
    private var sourceReady = false
    private var timer: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var localMonitor: Any?
    private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var generation = UUID()
    private var idleConnectionDeadline: TimeInterval = 0
    private let controlPort: NWEndpoint.Port
    private let videoPort: NWEndpoint.Port
    private let directControlPort: NWEndpoint.Port
    private let directVideoPort: NWEndpoint.Port
    private let enableBonjour: Bool
    var listeningPorts: [NWEndpoint.Port] { listeners.compactMap(\.port).filter { $0.rawValue != 0 } }
    private(set) var presentedFrameCount: UInt64 = 0
    nonisolated static let serviceType = "_unispace-win._tcp"
    nonisolated static let videoType = "_unispace-vid._tcp"

    public init(controlPort: NWEndpoint.Port = 61_343, videoPort: NWEndpoint.Port = 61_344, enableBonjour: Bool = true,
                directControlPort: NWEndpoint.Port = 61_343, directVideoPort: NWEndpoint.Port = 61_344,
                capture: (any SeamlessCaptureSource)? = nil) {
        self.controlPort = controlPort; self.videoPort = videoPort; self.enableBonjour = enableBonjour
        self.directControlPort = directControlPort; self.directVideoPort = directVideoPort
        self.capture = capture ?? SeamlessWindowCapture()
    }

    public func start(workspace: WorkspaceSnapshot, local: DeviceID, key: Data) throws {
        guard key.count == 32 else { throw SeamlessWindowError.permissionDenied }
        if let current = configuration,
           current.workspace.id == workspace.id, current.local == local, current.key == key {
            configuration = (workspace, local, key)
            return
        }
        stop()
        configuration = (workspace, local, key)
        let generation = self.generation
        do {
            for (lane, port, type) in [(SeamlessWindowConnection.Lane.control, controlPort, Self.serviceType),
                                       (.video, videoPort, Self.videoType)] {
                let listener = try NWListener(using: SeamlessWindowConnection.parameters(), on: port)
                if enableBonjour { listener.service = NWListener.Service(name: local.description, type: type) }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { connection.cancel(); return }
                        self.attach(connection, lane: lane, expected: nil)
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state {
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == generation else { return }
                            self.stop(); self.report("Window sharing could not listen on the network. Try enabling it again.")
                        }
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
                listeners.append(listener)
            }
            if enableBonjour {
            let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: SeamlessWindowConnection.parameters())
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    var endpoints: [DeviceID: NWEndpoint] = [:]
                    for result in results {
                        guard case let .service(name, _, _, _) = result.endpoint,
                              let uuid = UUID(uuidString: name) else { continue }
                        let peer = DeviceID(rawValue: uuid)
                        if self.allowed.contains(peer) { endpoints[peer] = result.endpoint }
                    }
                    self.endpoints = endpoints
                    self.availablePeers = Set(endpoints.keys)
                    self.onChange?()
                }
            }
            browser.start(queue: .global(qos: .userInitiated)); self.browser = browser
            }
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            for (center, notification) in [
                (workspaceCenter, NSWorkspace.willSleepNotification),
                (workspaceCenter, NSWorkspace.screensDidSleepNotification),
                (workspaceCenter, NSWorkspace.sessionDidResignActiveNotification),
                (NotificationCenter.default, NSApplication.willTerminateNotification)
            ] {
                let observer = center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.end("system lifecycle") }
                }
                lifecycleObservers.append((center, observer))
            }
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self else { return }
                    self.tick()
                }
            }
            report("Choose a window and a paired Mac. Enable window sharing on both Macs.")
        } catch { stop(); throw error }
    }

    public func stop() {
        generation = UUID()
        returnHome()
        timer?.cancel(); timer = nil
        browser?.cancel(); browser = nil
        listeners.forEach { $0.cancel() }; listeners.removeAll()
        lifecycleObservers.forEach { $0.0.removeObserver($0.1) }; lifecycleObservers.removeAll()
        configuration = nil; endpoints.removeAll(); availablePeers.removeAll()
        report("Window sharing is off")
    }

    public func catalog() async throws -> [SeamlessWindowDescriptor] {
        guard configuration != nil, !isPresenting else { throw SeamlessWindowError.busy }
        return try await capture.catalog()
    }

    public func present(_ descriptor: SeamlessWindowDescriptor, on peer: DeviceID) throws {
        guard let configuration, allowed.contains(peer), !isPresenting else { throw SeamlessWindowError.unavailable }
        let input = try capture.inputTarget(for: descriptor.id)
        let lease = WindowPresentationLease(windowID: descriptor.id, source: configuration.local, destination: peer)
        try state.offer(lease, now: now)
        self.input = input; self.descriptor = descriptor; offerSent = false
        do {
            let endpoint = try endpoint(for: peer, video: false)
            let videoEndpoint = try self.endpoint(for: peer, video: true)
            attach(NWConnection(to: endpoint, using: SeamlessWindowConnection.parameters()), lane: .control, expected: peer)
            attach(NWConnection(to: videoEndpoint, using: SeamlessWindowConnection.parameters()), lane: .video, expected: peer)
            report("Connecting to \(name(peer))…")
        } catch { end("connection setup failed"); throw error }
    }

    /// Asks a peer for its window catalog, over a lightweight control-only
    /// connection (no lease, no video). The peer answers with `.catalogOffer`;
    /// see `remoteCatalog`. Idle-connection expiry (tick()) reclaims this if
    /// the user never follows up with `pull(_:from:)`.
    public func requestCatalog(from peer: DeviceID) throws {
        guard let configuration, allowed.contains(peer), !isPresenting else { throw SeamlessWindowError.unavailable }
        closeConnections()
        pendingCatalogRequest = peer
        remoteCatalog = nil
        do {
            let endpoint = try endpoint(for: peer, video: false)
            attach(NWConnection(to: endpoint, using: SeamlessWindowConnection.parameters()), lane: .control, expected: peer)
            report("Asking \(name(peer)) for its windows…")
        } catch { pendingCatalogRequest = nil; throw error }
    }

    public func fetchCatalog(from peer: DeviceID) async throws -> [SeamlessWindowDescriptor] {
        try requestCatalog(from: peer)
        let deadline = now + 5
        while now < deadline {
            try Task.checkCancellation()
            guard !isPresenting else { throw SeamlessWindowError.busy }
            if let catalog = remoteCatalog, catalog.peer == peer { return catalog.windows }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SeamlessWindowError.unavailable
    }

    /// Asks `peer` (the source this time) to present `descriptor` here. Reuses
    /// the control connection `requestCatalog` opened. The peer starts its
    /// own fresh present() in response, which needs that connection's slot
    /// free on both ends — closed here after a beat so the request itself
    /// (an async, queued send) has time to actually reach the wire first.
    public func pull(_ descriptor: SeamlessWindowDescriptor, from peer: DeviceID) throws {
        guard let requestConnection = control, requestConnection.peer == peer, !isPresenting else {
            throw SeamlessWindowError.unavailable
        }
        send(.pullRequest(descriptor))
        report("Asking \(name(peer)) to move \(descriptor.application) here…")
        // Only tear down if nothing has superseded this connection yet — the
        // peer's own present() may already be attaching its fresh pair.
        Task { [weak self, weak requestConnection] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, self.control === requestConnection else { return }
            self.closeConnections()
        }
    }

    public func accept() {
        guard let incoming, control?.peer == incoming.0.source else { end("accept without control"); return }
        guard video?.peer == incoming.0.source else {
            acceptanceRequested = true
            report("Waiting for the encrypted video connection…")
            return
        }
        do {
            try state.accept(incoming.0, now: now)
            self.incoming = nil
            acceptanceRequested = false
            let epoch = incoming.0.epoch
            let proxy = SeamlessWindowProxy(descriptor: incoming.1, sourceName: name(incoming.0.source))
            proxy.onInput = { [weak self] event in
                guard let self, self.state.lease?.epoch == epoch else { return }
                self.send(.input(epoch, event))
            }
            proxy.onClose = { [weak self] in self?.end("proxy closed") }
            proxy.onVisibility = { [weak self] in self?.send(.visibility(epoch, $0)) }
            proxy.onKeyframeNeeded = { [weak self] in self?.send(.keyframe(epoch)) }
            self.proxy = proxy
            presentedFrameCount = 0
            send(.accept(incoming.0))
            report("Showing \(incoming.1.application) from \(name(incoming.0.source))")
        } catch { end("accept failed") }
    }

    public func returnHome() {
        if let lease = state.lease { send(.release(lease.epoch)) }
        state.release(); incoming = nil; descriptor = nil; offerSent = false; visible = true; acceptanceRequested = false; sourceReady = false
        input?.releaseAll(); input = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        proxy?.close(); proxy = nil
        // Capture teardown must finish before another session can use its
        // SCStream, so it takes over captureTask. This must run unconditionally:
        // cancel() doesn't nil the reference, so the old `if captureTask == nil`
        // guard skipped the stop exactly when a capture was live, leaving
        // captureTask set forever — isPresenting stuck true, no further window
        // movable until relaunch.
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            await self.capture.stop()
            self.captureTask = nil; self.onChange?()
        }
        closeConnections()
        if configuration != nil { report("Window returned to its source Mac") }
    }

    private func end(_ reason: String) {
        DiagnosticLog().record("Seamless window ended: \(reason)")
        returnHome()
    }

    private func closeConnections() {
        let old = Array(connections.values)
        connections.removeAll(); control = nil; video = nil
        old.forEach { $0.close() }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var allowed: Set<DeviceID> {
        guard let configuration else { return [] }
        return Set(configuration.workspace.devices.filter { $0.id != configuration.local && $0.platform == .macOS }.map(\.id))
    }
    private func name(_ peer: DeviceID) -> String {
        configuration?.workspace.devices.first { $0.id == peer }?.name ?? "Paired Mac"
    }
    private func report(_ text: String) { status = text; onChange?() }
    private func endpoint(for peer: DeviceID, video: Bool) throws -> NWEndpoint {
        if let endpoint = endpoints[peer], case let .service(name, _, domain, interface) = endpoint {
            return .service(name: name, type: video ? Self.videoType : Self.serviceType, domain: domain, interface: interface)
        }
        guard let host = configuration?.workspace.devices.first(where: { $0.id == peer })?.peerAddresses.first?.host else {
            throw SeamlessWindowError.unavailable
        }
        return .hostPort(host: NWEndpoint.Host(host), port: video ? directVideoPort : directControlPort)
    }

    private func attach(_ network: NWConnection, lane: SeamlessWindowConnection.Lane, expected: DeviceID?) {
        guard let configuration, connections.count < 4 else { network.cancel(); return }
        if connections.isEmpty { idleConnectionDeadline = now + SeamlessWindowLimits.leaseDuration }
        let id = UUID()
        do {
            let connection = try SeamlessWindowConnection(connection: network, lane: lane,
                workspace: configuration.workspace.id, local: configuration.local,
                allowed: allowed, expected: expected, key: configuration.key)
            connections[id] = connection
            connection.onReady = { [weak self, weak connection] peer in
                guard let self, let connection, self.connections[id] != nil else { return }
                let selectedPeer = self.state.lease.map { $0.source == configuration.local ? $0.destination : $0.source }
                guard selectedPeer == nil || selectedPeer == peer,
                      (self.control?.peer ?? self.video?.peer).map({ $0 == peer }) ?? true else { connection.close(); return }
                if lane == .control {
                    guard self.control == nil else { connection.close(); return }; self.control = connection
                    if self.pendingCatalogRequest == peer { self.send(.catalogRequest) }
                } else {
                    guard self.video == nil else { connection.close(); return }; self.video = connection
                }
                self.offerIfReady()
                if self.acceptanceRequested { self.accept() }
            }
            connection.onPacket = { [weak self] peer, data in self?.receive(peer: peer, lane: lane, data: data) }
            connection.onClosed = { [weak self, weak connection] in
                guard let self, self.connections.removeValue(forKey: id) != nil else { return }
                if self.control === connection || self.video === connection {
                    self.end("connection closed"); self.report("Connection ended. The window is available on its source Mac.")
                }
            }
            connection.start()
        } catch { network.cancel() }
    }

    private func offerIfReady() {
        guard let lease = state.lease, let descriptor, configuration?.local == lease.source,
              control?.peer == lease.destination, video?.peer == lease.destination, !offerSent else { return }
        offerSent = true
        send(.offer(lease, descriptor))
        report("Waiting for \(name(lease.destination)) to accept the window…")
    }

    private func send(_ message: SeamlessWindowMessage) {
        guard let data = try? SeamlessWindowCodec.encode(message) else { return }
        control?.send(data)
    }

    private func receive(peer: DeviceID, lane: SeamlessWindowConnection.Lane, data: Data) {
        do {
            if lane == .video {
                guard let lease = state.lease, lease.source == peer, proxy != nil else { throw SeamlessWindowError.staleLease }
                let frame = try SeamlessWindowCodec.decodeFrame(data)
                guard frame.epoch == lease.epoch else { throw SeamlessWindowError.staleLease }
                do { try state.receive(frame) }
                catch { send(.keyframe(lease.epoch)); return }
                if try proxy?.display(frame) == true { presentedFrameCount &+= 1 }
                return
            }
            let message = try SeamlessWindowCodec.decode(data)
            if case let .offer(lease, descriptor) = message {
                guard lease.source == peer, lease.destination == configuration?.local, !isPresenting else {
                    send(.reject(lease.epoch)); return
                }
                try state.offer(lease, now: now)
                incoming = (lease, descriptor)
                accept()
                return
            }
            if case .catalogRequest = message {
                guard !isPresenting else { return }
                Task { [weak self] in
                    guard let self, let list = try? await self.catalog() else { return }
                    self.send(.catalogOffer(Array(list.prefix(64))))
                }
                return
            }
            if case let .catalogOffer(descriptors) = message {
                guard pendingCatalogRequest == peer else { return }
                remoteCatalog = (peer, descriptors)
                pendingCatalogRequest = nil
                report("\(name(peer)) has \(descriptors.count) window\(descriptors.count == 1 ? "" : "s") available")
                onChange?()
                return
            }
            if case let .pullRequest(descriptor) = message {
                guard !isPresenting else { return }
                closeConnections()
                try? present(descriptor, on: peer)
                return
            }
            guard let lease = state.lease, peer == (lease.source == configuration?.local ? lease.destination : lease.source) else {
                throw SeamlessWindowError.staleLease
            }
            switch message {
            case let .accept(value):
                guard lease.source == configuration?.local, value == lease else { throw SeamlessWindowError.staleLease }
                try state.accept(value, now: now)
                beginCapture(lease)
            case let .heartbeat(epoch): try state.renew(epoch: epoch, now: now)
            case let .release(epoch), let .reject(epoch):
                guard epoch == lease.epoch else { throw SeamlessWindowError.staleLease }
                end("peer release")
            case let .input(epoch, event):
                guard state.authorizes(epoch: epoch, peer: peer, now: now) else { throw SeamlessWindowError.staleLease }
                // The proxy can send input (e.g. a resign-key releaseAll) in the
                // brief window between accept and the first video frame — drop
                // it rather than tearing down an otherwise-healthy session.
                guard sourceReady else { return }
                try input?.send(event)
            case let .keyframe(epoch):
                guard state.authorizes(epoch: epoch, peer: peer, now: now) else { throw SeamlessWindowError.staleLease }
                capture.requestKeyframe()
            case let .visibility(epoch, visible):
                guard state.authorizes(epoch: epoch, peer: peer, now: now) else { throw SeamlessWindowError.staleLease }
                self.visible = visible; input?.releaseAll()
                capture.setPaused(!visible)
                if visible { capture.requestKeyframe() }
            case .resize, .offer, .catalogRequest, .catalogOffer, .pullRequest: throw SeamlessWindowError.invalidMessage
            }
        } catch { end("invalid session message"); report("Window sharing stopped because the session was no longer valid.") }
    }

    private func beginCapture(_ lease: WindowPresentationLease) {
        guard captureTask == nil else { end("capture already active"); return }
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.capture.start(id: lease.windowID, epoch: lease.epoch, onFrame: { [weak self] frame in
                    guard let self, self.state.lease?.epoch == lease.epoch, self.visible,
                          let data = try? SeamlessWindowCodec.encode(frame) else { return false }
                    let sent = self.video?.send(data) ?? false
                    if sent { self.sourceReady = true }
                    return sent
                }, onFailure: { [weak self] in
                    guard self?.state.lease?.epoch == lease.epoch else { return }
                    self?.end("capture stopped")
                })
                guard !Task.isCancelled, self.state.lease == lease else {
                    await self.capture.stop(); self.captureTask = nil; self.onChange?(); return
                }
                self.captureTask = nil
                self.localMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                    guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != uniSpaceSyntheticEventMarker else { return }
                    Task { @MainActor [weak self] in self?.end("local input") }
                }
                self.report("Sharing \(self.descriptor?.application ?? "window") with \(self.name(lease.destination))")
            } catch {
                self.captureTask = nil
                self.end("capture start failed"); self.report("Could not capture this window. Check Screen Recording and Accessibility permissions.")
            }
        }
    }

    private func tick() {
        if state.phase == .idle, !connections.isEmpty, now >= idleConnectionDeadline { end("idle timeout"); return }
        if state.expire(now: now) { end("lease expired"); report("The window session expired and returned home."); return }
        if state.phase == .presenting, let lease = state.lease {
            if lease.source == configuration?.local && input?.isAvailable != true { end("input unavailable"); return }
            send(.heartbeat(lease.epoch))
        }
    }
}
