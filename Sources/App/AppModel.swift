import AppKit
import Combine
import Foundation
import UniSpaceApplication
import UniSpaceDomain
import UniSpaceInfrastructure

@MainActor
final class AppModel: ObservableObject {
    private struct PendingActivationInput {
        let initialEvent: InputEvent?
        let stream: AsyncStream<InputEvent>
        let continuation: AsyncStream<InputEvent>.Continuation
    }

    enum SetupState: Equatable {
        case needsWorkspace
        case ready
        case hostingPairing
        case browsing
        case confirming(PairingPrompt)
    }

    @Published private(set) var setupState: SetupState = .needsWorkspace
    @Published private(set) var workspace: WorkspaceSnapshot?
    @Published private(set) var candidates: [PairingCandidate] = []
    @Published private(set) var connectedDevices: Set<DeviceID> = []
    @Published private(set) var connectionSnapshots: [DeviceID: ConnectionSnapshot] = [:]
    @Published private(set) var currentControllerID: DeviceID?
    @Published private(set) var controlSessionSnapshot = ControlSessionSnapshot.idle
    @Published private(set) var workspaceKeyRevision: UInt64 = 0
    @Published private(set) var statusMessage = "Not configured"
    @Published var lastError: String?
    @Published private(set) var inputMonitoringPermission: PermissionState = .unknown
    @Published private(set) var postEventsPermission: PermissionState = .unknown
    @Published private(set) var launchAtLogin = false

    private let workspaceStore = FileWorkspaceStore()
    private let trustStore = KeychainTrustStore()
    private let controllerIdentityStore = UserDefaultsControllerIdentityStore()
    private let permissionService = SystemPermissionService()
    private let displayCatalog = SystemDisplayCatalog()
    private let tailnetAddressProvider = SystemTailnetAddressProvider()
    private let loginItemController = SystemLoginItemController()
    private let transport = NetworkPeerTransport()
    private let pairing = PairingNetworkService()
    private let capture = CGEventInputCapture()
    private let injector = CGEventInputInjector()
    private var coordinator: ControlSessionCoordinator?
    private var networkTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var networkRestartTask: Task<Void, Never>?
    private var screenChangeSubscription: AnyCancellable?
    private var currentEpoch: ControllerEpoch?
    private var lastBoundaryTime: UInt64 = 0
    private var controlTransferGuard = ControlTransferGuard()
    private var pendingActivationInput: PendingActivationInput?

    let localDeviceID: DeviceID

    init() {
        self.localDeviceID = Self.loadDeviceID()
        configurePairingCallbacks()
        injector.pointerPositionHandler = { [weak self] x, y in
            Task { @MainActor [weak self] in await self?.handleInjectedPointer(x: x, y: y) }
        }
        refreshPermissions()
        launchAtLogin = loginItemController.isEnabled
        screenChangeSubscription = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLocalDisplays() }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-onboarding") {
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-hosting") {
            setupState = .hostingPairing
            statusMessage = "Visible to nearby devices"
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-connections") {
            let local = localDevice
            let remoteID = DeviceID()
            let remote = DeviceDescriptor(id: remoteID, name: "Office PC", platform: .windows)
            workspace = WorkspaceSnapshot(
                id: WorkspaceID(),
                name: "My UniSpace",
                localDeviceID: localDeviceID,
                devices: [local, remote]
            )
            connectionSnapshots[remoteID] = .init(
                health: .reconnecting,
                transport: .tcp,
                detail: "The trusted peer is temporarily unavailable"
            )
            setupState = .ready
            statusMessage = "Restoring the workspace connection"
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-configured") {
            let device = localDevice
            workspace = WorkspaceSnapshot(
                id: WorkspaceID(),
                name: "My UniSpace",
                localDeviceID: localDeviceID,
                devices: [device]
            )
            setupState = .ready
            statusMessage = "Ready on your private network"
            return
        }
        do {
            workspace = try workspaceStore.load()
            if let workspace {
                currentControllerID = controllerIdentityStore.controllerID(for: workspace.id)
                currentEpoch = currentControllerID.map {
                    ControllerEpoch(generation: workspace.generation, controllerID: $0)
                }
                setupState = .ready
                Task { await startTrustedNetwork(claimControl: false) }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    deinit {
        networkTask?.cancel()
        sessionTask?.cancel()
        networkRestartTask?.cancel()
    }

    var localDevice: DeviceDescriptor {
        DeviceDescriptor(
            id: localDeviceID,
            name: Host.current().localizedName ?? "Mac",
            displays: displayCatalog.currentDisplays(for: localDeviceID),
            peerAddresses: tailnetAddressProvider.currentAddresses(),
            capabilities: [
                .publicTrackpadGestures,
                .portableTrackpadGestures,
                .crossPlatformInputV2,
                .quicStreamV2,
                .udpPointerV2,
                .activationAcknowledgementV1,
                .fileTransferV1,
                .clipboardTextV1,
                .clipboardURLV1,
            ],
            platform: .macOS
        )
    }

    var tailnetAddresses: [PeerAddress] { tailnetAddressProvider.currentAddresses() }

    var devices: [DeviceDescriptor] { workspace?.devices ?? [] }
    var allDisplays: [DisplayDescriptor] { devices.flatMap(\.displays) }
    var isLocalController: Bool { currentControllerID == localDeviceID }
    var peerConnectionPolicy: PeerConnectionPolicy {
        guard let workspace else { return .passive }
        return ControlConnectionRoutingPolicy.policy(
            localDeviceID: localDeviceID,
            workspace: workspace,
            controllerID: currentControllerID
        )
    }
    var hasReconnectableDevices: Bool {
        !peerConnectionPolicy.outboundPeerIDs.subtracting(connectedDevices).isEmpty
    }

    var needsPermissions: Bool {
        inputMonitoringPermission != .granted || postEventsPermission != .granted
    }

    func createWorkspace() {
        let device = localDevice
        let snapshot = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "My UniSpace",
            localDeviceID: localDeviceID,
            devices: [device]
        )
        let key = PairingCryptoSession.randomData(count: 32)
        do {
            try trustStore.storeWorkspaceKey(key, for: snapshot.id)
            workspaceKeyRevision &+= 1
            try workspaceStore.save(snapshot)
            workspace = snapshot
            setupState = .ready
            Task { await startTrustedNetwork(claimControl: true) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startHostingPairing() {
        guard let workspace else { return }
        do {
            guard let key = try trustStore.workspaceKey(for: workspace.id) else { return }
            try pairing.startHosting(workspace: workspace, key: key, localDevice: localDevice)
            setupState = .hostingPairing
            statusMessage = "Starting local discovery"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startBrowsingForWorkspace() {
        setupState = .browsing
        statusMessage = "Looking for UniSpace workspaces"
        // UI tests verify the setup flow, not macOS local-network authorization.
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing-onboarding") else { return }
        pairing.startBrowsing()
    }

    func join(_ candidate: PairingCandidate) {
        do {
            try pairing.join(candidate, localDevice: localDevice)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func joinDirectly(address rawAddress: String) {
        do {
            let address = try PeerAddress(rawAddress)
            try pairing.join(address, localDevice: localDevice)
            statusMessage = "Connecting to \(address.host) through Tailscale"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setConnectionAddress(_ rawAddress: String, for deviceID: DeviceID) {
        guard deviceID != localDeviceID, var workspace,
              let index = workspace.devices.firstIndex(where: { $0.id == deviceID }) else { return }
        do {
            let address = try PeerAddress(rawAddress)
            workspace.devices[index].peerAddresses = [address]
            try workspaceStore.save(workspace)
            self.workspace = workspace
            statusMessage = "Connecting to \(workspace.devices[index].name) through Tailscale"
            Task { await startTrustedNetwork(claimControl: isLocalController) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func confirmPairing() { pairing.confirm() }

    func cancelPairing() {
        pairing.reject()
        candidates = []
        setupState = workspace == nil ? .needsWorkspace : .ready
    }

    func leaveWorkspace() async {
        guard let workspace else { return }
        let wasLocalController = isLocalController

        pairing.stop()
        candidates = []
        networkTask?.cancel()
        networkTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        finishPendingActivationInput()
        await coordinator?.stop()
        coordinator = nil
        await transport.stop()
        injector.releaseAll()

        let result: LeaveWorkspaceResult
        do {
            result = try WorkspaceLifecycle(
                workspaceStore: workspaceStore,
                trustStore: trustStore
            ).leave(workspaceID: workspace.id)
        } catch {
            let message = "UniSpace could not remove this Mac’s local workspace: \(error.localizedDescription)"
            await startTrustedNetwork(claimControl: wasLocalController)
            lastError = message
            return
        }

        self.workspace = nil
        controllerIdentityStore.setControllerID(nil, for: workspace.id)
        connectedDevices = []
        currentControllerID = nil
        currentEpoch = nil
        lastBoundaryTime = 0
        controlTransferGuard.reset()
        setupState = .needsWorkspace
        statusMessage = "Not configured"

        if result == .trustKeyCleanupFailed {
            lastError = "This Mac left the workspace, but UniSpace could not remove its old encryption key from Keychain."
        }
    }

    func makeThisMacController() {
        Task {
            guard let coordinator else { return }
            let epoch = await coordinator.makeLocalController()
            controlTransferGuard.reset()
            currentEpoch = epoch
            currentControllerID = localDeviceID
            if let workspace {
                controllerIdentityStore.setControllerID(localDeviceID, for: workspace.id)
            }
            transport.updateConnectionPolicy(peerConnectionPolicy)
            if var workspace, epoch.generation > workspace.generation {
                workspace.generation = epoch.generation
                persistAndBroadcastLocally(workspace)
            }
            await broadcast(ControlEnvelope(message: .controllerClaim(epoch)))
            statusMessage = "This Mac controls the workspace"
        }
    }

    func stopControlling() {
        controlTransferGuard.beginStop()
        finishPendingActivationInput()
        capture.setSuppressionEnabled(false)
        Task {
            await coordinator?.deactivateCurrentSession()
            controlTransferGuard.completeStop()
            statusMessage = isLocalController ? "Controller ready" : "Receiver ready"
        }
    }

    func request(_ permission: PermissionKind) {
        _ = permissionService.request(permission)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPermissions()
            self?.startCaptureIfPossible()
        }
    }

    func refreshPermissions() {
        inputMonitoringPermission = permissionService.state(for: .inputMonitoring)
        postEventsPermission = permissionService.state(for: .postEvents)
    }

    func refreshConnections() {
        let allowed = peerConnectionPolicy.outboundPeerIDs
        let offline = devices.filter { allowed.contains($0.id) && !connectedDevices.contains($0.id) }
        guard !offline.isEmpty else {
            statusMessage = allowed.isEmpty
                ? "Waiting for the controller to restore connections"
                : "All devices are connected"
            return
        }
        for device in offline {
            reconnect(to: device.id)
        }
        statusMessage = offline.count == 1
            ? "Refreshing connection to \(offline[0].name)"
            : "Refreshing \(offline.count) connections"
    }

    func reconnect(to deviceID: DeviceID) {
        guard deviceID != localDeviceID,
              peerConnectionPolicy.outboundPeerIDs.contains(deviceID),
              let device = devices.first(where: { $0.id == deviceID }),
              !connectedDevices.contains(deviceID) else { return }
        let transportKind = connectionSnapshots[deviceID]?.transport ?? .tcp
        connectionSnapshots[deviceID] = .init(
            health: .reconnecting,
            transport: transportKind,
            detail: connectionSnapshots[deviceID]?.detail
        )
        statusMessage = "Refreshing connection to \(device.name)"
        transport.reconnect(to: deviceID)
    }

    func restartNetworking() {
        guard networkRestartTask == nil else { return }
        let shouldRetainControl = isLocalController
        statusMessage = "Restarting networking"
        networkRestartTask = Task { [weak self] in
            guard let self else { return }
            await self.startTrustedNetwork(claimControl: shouldRetainControl)
            self.networkRestartTask = nil
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItemController.setEnabled(enabled)
            launchAtLogin = loginItemController.isEnabled
        } catch {
            lastError = error.localizedDescription
            launchAtLogin = loginItemController.isEnabled
        }
    }

    func connect(_ first: DisplayEndpoint, to second: DisplayEndpoint) {
        guard var workspace else { return }
        workspace.topology.connect(first, to: second)
        persistAndBroadcast(workspace)
    }

    func disconnect(_ endpoint: DisplayEndpoint) {
        guard var workspace else { return }
        workspace.topology.disconnect(endpoint)
        persistAndBroadcast(workspace)
    }

    /// Opens the relevant Privacy & Security pane. The Core Graphics prompts
    /// only ever appear once, so a denied permission can otherwise only be
    /// changed in System Settings.
    func openSystemSettings(for permission: PermissionKind) {
        let anchor: String
        switch permission {
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .postEvents: anchor = "Privacy_Accessibility"
        case .localNetwork: anchor = "Privacy_LocalNetwork"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    func removeDevice(_ deviceID: DeviceID) {
        guard deviceID != localDeviceID, var workspace else { return }
        Task {
            let removedDisplays = Set(workspace.devices.first(where: { $0.id == deviceID })?.displays.map(\.id) ?? [])
            workspace.devices.removeAll { $0.id == deviceID }
            if currentControllerID == deviceID {
                currentControllerID = nil
                currentEpoch = nil
                controllerIdentityStore.setControllerID(nil, for: workspace.id)
            }
            workspace.topology.links.removeAll {
                removedDisplays.contains($0.source.displayID) || removedDisplays.contains($0.destination.displayID)
            }
            let newKey = PairingCryptoSession.randomData(count: 32)
            for peer in workspace.devices where peer.id != localDeviceID && connectedDevices.contains(peer.id) {
                try? await transport.send(ControlEnvelope(message: .workspace(workspace)), to: peer.id)
                try? await transport.send(ControlEnvelope(message: .rotateWorkspaceKey(newKey)), to: peer.id)
            }
            do {
                try trustStore.rotateWorkspaceKey(newKey, for: workspace.id)
                workspaceKeyRevision &+= 1
                try workspaceStore.save(workspace)
                self.workspace = workspace
                await startTrustedNetwork(claimControl: isLocalController)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func dismissError() { lastError = nil }

    private func configurePairingCallbacks() {
        pairing.candidatesHandler = { [weak self] candidates in
            Task { @MainActor [weak self] in self?.candidates = candidates }
        }
        pairing.promptHandler = { [weak self] prompt in
            Task { @MainActor [weak self] in
                self?.setupState = .confirming(prompt)
                self?.statusMessage = "Confirm the code on both devices"
            }
        }
        pairing.joinedHandler = { [weak self] snapshot, key in
            Task { @MainActor [weak self] in self?.completeJoin(snapshot: snapshot, key: key) }
        }
        pairing.hostUpdatedHandler = { [weak self] snapshot in
            Task { @MainActor [weak self] in self?.completeHostPairing(snapshot: snapshot) }
        }
        pairing.failureHandler = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.lastError = message
                self?.setupState = self?.workspace == nil ? .needsWorkspace : .ready
            }
        }
        pairing.statusHandler = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .ready:
                    self.statusMessage = self.setupState == .hostingPairing
                        ? "Visible to nearby devices as \(self.localDevice.name)"
                        : "Searching the local network"
                case let .waiting(message):
                    self.statusMessage = "Waiting for local network access: \(message)"
                case let .failed(message):
                    self.lastError = "Local network discovery failed: \(message)"
                    self.setupState = self.workspace == nil ? .needsWorkspace : .ready
                }
            }
        }
    }

    private func completeJoin(snapshot: WorkspaceSnapshot, key: Data) {
        do {
            try trustStore.storeWorkspaceKey(key, for: snapshot.id)
            workspaceKeyRevision &+= 1
            try workspaceStore.save(snapshot)
            workspace = snapshot
            currentControllerID = controllerIdentityStore.controllerID(for: snapshot.id)
            currentEpoch = currentControllerID.map {
                ControllerEpoch(generation: snapshot.generation, controllerID: $0)
            }
            setupState = .ready
            Task { await startTrustedNetwork(claimControl: false) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func completeHostPairing(snapshot: WorkspaceSnapshot) {
        var snapshot = snapshot
        let shouldRetainControl = isLocalController
        if snapshot.topology.links.isEmpty,
           let localDisplay = snapshot.devices.first(where: { $0.id == localDeviceID })?.displays.first(where: \.isMain),
           let remoteDisplay = snapshot.devices.first(where: { $0.id != localDeviceID })?.displays.first(where: \.isMain) {
            snapshot.topology.connect(
                DisplayEndpoint(displayID: localDisplay.id, edge: .right),
                to: DisplayEndpoint(displayID: remoteDisplay.id, edge: .left)
            )
        }
        do {
            try workspaceStore.save(snapshot)
            workspace = snapshot
            setupState = .ready
            statusMessage = "Paired successfully"
            // Restart so capability-gated Windows QUIC and pointer listeners are
            // created immediately for the newly trusted receiver.
            Task { await startTrustedNetwork(claimControl: shouldRetainControl) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persistAndBroadcast(_ snapshot: WorkspaceSnapshot) {
        do {
            try workspaceStore.save(snapshot)
            workspace = snapshot
            Task { await broadcast(ControlEnvelope(message: .workspace(snapshot))) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func startTrustedNetwork(claimControl: Bool) async {
        guard let workspace else { return }
        do {
            controlTransferGuard.reset()
            guard let keyring = try trustStore.workspaceKeyring(for: workspace.id) else { return }
            networkTask?.cancel()
            networkTask = nil
            sessionTask?.cancel()
            sessionTask = nil
            await coordinator?.stop()
            coordinator = nil
            await transport.stop()
            injector.releaseAll()
            connectedDevices.removeAll()
            connectionSnapshots = Dictionary(uniqueKeysWithValues: workspace.devices.compactMap { device in
                guard device.id != localDeviceID else { return nil }
                let previous = connectionSnapshots[device.id]
                return (device.id, ConnectionSnapshot(
                    health: .reconnecting,
                    transport: previous?.transport ?? .tcp,
                    detail: previous?.detail
                ))
            })
            let local = refreshedLocalDevice(in: workspace)
            guard let refreshedWorkspace = self.workspace else { return }
            try await transport.start(
                localDevice: local,
                workspace: refreshedWorkspace,
                workspaceKeys: keyring.candidates
            )
            let coordinator = ControlSessionCoordinator(
                localDeviceID: localDeviceID,
                workspaceID: workspace.id,
                capture: capture,
                injector: injector,
                transport: transport,
                election: ControllerStateMachine(
                    currentEpoch: currentEpoch,
                    nextGeneration: workspace.generation + 1
                )
            )
            self.coordinator = coordinator
            transport.updateConnectionPolicy(peerConnectionPolicy)
            startCaptureIfPossible()
            networkTask = Task { [weak self] in
                guard let self else { return }
                for await event in transport.events() {
                    if Task.isCancelled { break }
                    await self.handlePeerEvent(event)
                }
            }
            sessionTask = Task { [weak self, coordinator] in
                for await snapshot in await coordinator.sessionSnapshots() {
                    guard !Task.isCancelled, let self else { return }
                    if self.controlSessionSnapshot != snapshot {
                        let previous = self.controlSessionSnapshot
                        self.controlSessionSnapshot = snapshot
                        if snapshot.phase == .idle, previous.phase != .idle {
                            self.finishPendingActivationInput()
                            if previous.phase == .receiving {
                                self.controlTransferGuard.reset()
                            } else {
                                self.controlTransferGuard.beginStop()
                                self.controlTransferGuard.completeStop()
                                self.statusMessage = "Control returned to this Mac"
                            }
                        }
                    }
                }
            }
            setupState = .ready
            statusMessage = "Ready on your private network"
            if claimControl { makeThisMacController() }
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Network unavailable"
        }
    }

    private func refreshedLocalDevice(in snapshot: WorkspaceSnapshot) -> DeviceDescriptor {
        var current = localDevice
        var updated = snapshot
        if let index = updated.devices.firstIndex(where: { $0.id == localDeviceID }) {
            current.peerAddresses = WorkspaceReplicaMerger.mergeAddresses(
                updated.devices[index].peerAddresses,
                current.peerAddresses
            )
            updated.updateDevice(current)
        }
        if updated != workspace {
            try? workspaceStore.save(updated)
            workspace = updated
        }
        return current
    }

    private func startCaptureIfPossible() {
        guard inputMonitoringPermission == .granted else { return }
        do {
            try capture.start { [weak self] event in
                guard Thread.isMainThread else {
                    Task { @MainActor [weak self] in self?.captureSynchronously(event) }
                    return false
                }
                return MainActor.assumeIsolated {
                    self?.captureSynchronously(event) ?? false
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    private func captureSynchronously(_ event: InputEvent) -> Bool {
        if let pendingActivationInput {
            pendingActivationInput.continuation.yield(event)
            return true
        }
        if case let .pointerMove(_, _, x, y) = event {
            controlTransferGuard.observe(x: x, y: y)
            if !capture.isSuppressionEnabled,
               isLocalController,
               coordinator != nil,
               let workspace,
               let transition = EdgeRouter.transition(
                    x: x,
                    y: y,
                    localDeviceID: localDeviceID,
                    devices: workspace.devices,
                    topology: workspace.topology,
                    availableDeviceIDs: routableDeviceIDs
               ), controlTransferGuard.allows(transition),
               let sourceDisplay = workspace.devices.flatMap(\.displays).first(where: {
                   $0.id == transition.sourceDisplayID
               }),
               let attempt = controlTransferGuard.beginActivation(
                   transition,
                   sourceDisplay: sourceDisplay
               ) {
                let pair = AsyncStream<InputEvent>.makeStream(
                    bufferingPolicy: .bufferingNewest(256)
                )
                pendingActivationInput = PendingActivationInput(
                    initialEvent: event,
                    stream: pair.stream,
                    continuation: pair.continuation
                )
                capture.setSuppressionEnabled(true)
                Task { @MainActor [weak self] in
                    await self?.completeActivation(transition, attempt: attempt)
                }
                return true
            }
        }
        guard controlTransferGuard.forwardsCapturedInput else { return false }
        Task { @MainActor [weak self] in await self?.forwardCaptured(event) }
        return false
    }

    private func completeActivation(
        _ transition: EdgeTransition,
        attempt: ControlTransferGuard.ActivationAttempt
    ) async {
        guard let coordinator else {
            controlTransferGuard.activationFailed(attempt)
            finishPendingActivationInput()
            capture.setSuppressionEnabled(false)
            return
        }
        guard let pending = pendingActivationInput else {
            controlTransferGuard.activationFailed(attempt)
            capture.setSuppressionEnabled(false)
            return
        }
        do {
            try await coordinator.activate(
                target: transition.targetDeviceID,
                displayID: transition.targetDisplayID,
                entryEdge: transition.entryEdge,
                normalizedPosition: transition.normalizedPosition,
                targetCapabilities: capabilities(of: transition.targetDeviceID),
                requiresActivationConfirmation: true,
                initialEvent: pending.initialEvent,
                pendingEvents: pending.stream
            )
            guard case .controlling = await coordinator.currentState() else {
                controlTransferGuard.activationFailed(attempt)
                finishPendingActivationInput()
                capture.setSuppressionEnabled(false)
                return
            }
            guard controlTransferGuard.activationSucceeded(attempt) else {
                finishPendingActivationInput()
                await coordinator.deactivateCurrentSession()
                capture.setSuppressionEnabled(false)
                return
            }
            statusMessage = "Controlling \(deviceName(transition.targetDeviceID))"
        } catch {
            controlTransferGuard.activationFailed(attempt)
            finishPendingActivationInput()
            capture.setSuppressionEnabled(false)
            lastError = error.localizedDescription
        }
    }

    private func forwardCaptured(_ event: InputEvent) async {
        guard let coordinator else { return }
        if await coordinator.handleCaptured(event) == .emergencyStop {
            controlTransferGuard.beginStop()
            controlTransferGuard.completeStop()
            statusMessage = "Control returned to this Mac"
        }
    }

    private func finishPendingActivationInput() {
        pendingActivationInput?.continuation.finish()
        pendingActivationInput = nil
    }

    private func handleInjectedPointer(x: Double, y: Double) async {
        let now = DispatchTime.now().uptimeNanoseconds
        controlTransferGuard.observe(x: x, y: y)
        guard let coordinator,
              case let .receiving(_, source, sessionID) = await coordinator.currentState(),
              let workspace,
              let transition = EdgeRouter.transition(
                x: x,
                y: y,
                localDeviceID: localDeviceID,
                devices: workspace.devices,
                topology: workspace.topology
              ), controlTransferGuard.allows(transition),
              now - lastBoundaryTime > 250_000_000 else { return }
        lastBoundaryTime = now
        try? await transport.send(
            ControlEnvelope(message: .boundaryCrossed(
                sessionID: sessionID,
                displayID: transition.sourceDisplayID,
                edge: transition.sourceEdge,
                normalizedPosition: transition.normalizedPosition
            )),
            to: source
        )
    }

    private func handlePeerEvent(_ event: PeerEvent) async {
        switch event {
        case let .discovered(device):
            upsert(device, capabilitiesAreAuthoritative: false)
        case .lost:
            break
        case let .connected(deviceID):
            connectedDevices.insert(deviceID)
            if let workspace {
                try? await transport.send(ControlEnvelope(message: .workspace(workspace)), to: deviceID)
            }
            if let currentEpoch {
                try? await transport.send(ControlEnvelope(message: .controllerClaim(currentEpoch)), to: deviceID)
            }
        case let .workspaceUpgradeRequired(deviceID):
            guard let workspace,
                  workspace.devices.contains(where: { $0.id == deviceID }),
                  let currentKey = try? trustStore.workspaceKey(for: workspace.id) else { break }
            try? await transport.send(ControlEnvelope(message: .workspace(workspace)), to: deviceID)
            try? await transport.send(
                ControlEnvelope(message: .rotateWorkspaceKey(currentKey)),
                to: deviceID
            )
        case let .disconnected(deviceID):
            connectedDevices.remove(deviceID)
            let previousConnection = connectionSnapshots[deviceID]
            connectionSnapshots[deviceID] = .init(
                health: .reconnecting,
                transport: previousConnection?.transport ?? .tcp,
                detail: previousConnection?.detail
            )
            let previousState = await coordinator?.currentState()
            await coordinator?.peerDisconnected(deviceID)
            if case let .receiving(_, source, _)? = previousState, source == deviceID {
                controlTransferGuard.reset()
            } else if case let .controlling(_, target, _)? = previousState, target == deviceID {
                controlTransferGuard.beginStop()
                controlTransferGuard.completeStop()
                statusMessage = "Connection lost — control returned to this Mac"
            }
        case let .control(source, envelope):
            await handleControl(envelope.message, from: source)
        case let .input(source, frame):
            await coordinator?.handleIncoming(frame, from: source)
        case let .realtimeInput(source, frame):
            await coordinator?.handleIncomingRealtime(frame, from: source)
        case let .health(deviceID, snapshot):
            if let deviceID { connectionSnapshots[deviceID] = snapshot }
            guard let deviceID, snapshot.health == .degraded,
                  case let .controlling(_, target, _)? = await coordinator?.currentState(),
                  target == deviceID else { break }
            statusMessage = "Slow \(snapshot.transport.rawValue.uppercased()) connection to \(deviceName(deviceID))"
        case let .failure(_, message):
            statusMessage = message
        }
    }

    private func handleControl(_ message: ControlMessage, from source: DeviceID) async {
        switch message {
        case let .hello(device):
            upsert(device, capabilitiesAreAuthoritative: true)
        case let .workspace(incoming):
            guard let currentWorkspace = workspace,
                  var workspace = WorkspaceReplicaMerger.mergeSnapshot(currentWorkspace, with: incoming) else { return }
            var current = localDevice
            if let persistedLocal = workspace.devices.first(where: { $0.id == localDeviceID }) {
                current.peerAddresses = WorkspaceReplicaMerger.mergeAddresses(
                    persistedLocal.peerAddresses,
                    current.peerAddresses
                )
            }
            workspace.updateDevice(current)
            persistAndBroadcastLocally(workspace)
        case let .controllerClaim(epoch):
            currentEpoch = max(currentEpoch ?? epoch, epoch)
            currentControllerID = currentEpoch?.controllerID
            if let workspace, let currentControllerID {
                controllerIdentityStore.setControllerID(currentControllerID, for: workspace.id)
            }
            transport.updateConnectionPolicy(peerConnectionPolicy)
            if var workspace, epoch.generation > workspace.generation {
                workspace.generation = epoch.generation
                persistAndBroadcastLocally(workspace)
            }
            await coordinator?.observeControllerClaim(epoch)
            statusMessage = currentControllerID == localDeviceID ? "This Mac controls the workspace" : "Receiver ready"
        case let .activate(activation):
            let display = workspace?.devices.flatMap(\.displays).first { $0.id == activation.targetDisplayID }
            refreshPermissions()
            let accepted = await coordinator?.receiveActivation(
                activation,
                from: source,
                targetDisplay: display,
                isInputInjectionAuthorized: postEventsPermission == .granted
            ) == true
            if capabilities(of: source).contains(.activationAcknowledgementV1) {
                try? await transport.send(
                    ControlEnvelope(message: .activationResult(
                        sessionID: activation.sessionID,
                        accepted: accepted
                    )),
                    to: source
                )
            }
            if accepted {
                if let display {
                    controlTransferGuard.returned(to: display, enteringFrom: activation.entryEdge)
                } else {
                    controlTransferGuard.reset()
                }
                statusMessage = "Controlled by \(deviceName(source))"
            }
        case let .activationResult(sessionID, accepted):
            _ = await coordinator?.receiveActivationResult(
                sessionID: sessionID,
                from: source,
                accepted: accepted
            )
        case .deactivate, .releaseAll:
            let previousState = await coordinator?.currentState()
            await coordinator?.deactivateCurrentSession()
            if case .receiving? = previousState {
                controlTransferGuard.reset()
            } else if case .activating? = previousState {
                controlTransferGuard.beginStop()
                controlTransferGuard.completeStop()
            } else if case .controlling? = previousState {
                controlTransferGuard.beginStop()
                controlTransferGuard.completeStop()
            }
            statusMessage = isLocalController ? "Controller ready" : "Receiver ready"
        case let .boundaryCrossed(sessionID, displayID, edge, normalizedPosition):
            await handleBoundaryCrossed(
                from: source,
                sessionID: sessionID,
                displayID: displayID,
                edge: edge,
                normalizedPosition: normalizedPosition
            )
        case let .heartbeat(sessionID, timestampNanos):
            if await coordinator?.receiveHeartbeat(sessionID: sessionID, from: source) == true {
                try? await transport.send(
                    ControlEnvelope(message: .heartbeat(
                        sessionID: sessionID,
                        timestampNanos: timestampNanos
                    )),
                    to: source
                )
            } else if let latency = await coordinator?.receiveHeartbeatEcho(
                sessionID: sessionID,
                from: source,
                sentAtNanos: timestampNanos
            ) {
                let transportKind = connectionSnapshots[source]?.transport ?? .tcp
                let health: ConnectionHealth = latency >= 500 ? .degraded : .healthy
                connectionSnapshots[source] = .init(
                    health: health,
                    transport: transportKind,
                    latencyMilliseconds: latency,
                    detail: health == .degraded ? "High network latency" : nil
                )
                if health == .degraded {
                    statusMessage = "Slow \(transportKind.rawValue.uppercased()) connection to \(deviceName(source))"
                }
            }
        case let .rotateWorkspaceKey(newKey):
            guard let workspace else { return }
            do {
                try trustStore.rotateWorkspaceKey(newKey, for: workspace.id)
                workspaceKeyRevision &+= 1
                await startTrustedNetwork(claimControl: isLocalController)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func handleBoundaryCrossed(
        from source: DeviceID,
        sessionID: SessionID,
        displayID: DisplayID,
        edge: DisplayEdge,
        normalizedPosition: Double
    ) async {
        guard isLocalController, let coordinator,
              case let .controlling(_, activeTarget, activeSession) = await coordinator.currentState(),
              activeTarget == source, activeSession == sessionID,
              let workspace,
              let destination = EdgeRouter.reachableDestination(
                  from: displayID,
                  edge: edge,
                  devices: workspace.devices,
                  topology: workspace.topology,
                  availableDeviceIDs: routableDeviceIDs.union([localDeviceID])
              ),
              let targetDisplay = workspace.devices.flatMap(\.displays).first(where: { $0.id == destination.displayID }) else { return }
        await coordinator.deactivateCurrentSession()
        if targetDisplay.deviceID == localDeviceID {
            injector.activate(on: targetDisplay, enteringFrom: destination.edge, normalizedPosition: normalizedPosition)
            controlTransferGuard.returned(to: targetDisplay, enteringFrom: destination.edge)
            statusMessage = "Controller ready"
        } else {
            let pair = AsyncStream<InputEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(256)
            )
            pendingActivationInput = PendingActivationInput(
                initialEvent: nil,
                stream: pair.stream,
                continuation: pair.continuation
            )
            try? await coordinator.activate(
                target: targetDisplay.deviceID,
                displayID: targetDisplay.id,
                entryEdge: destination.edge,
                normalizedPosition: normalizedPosition,
                targetCapabilities: capabilities(of: targetDisplay.deviceID),
                requiresActivationConfirmation: true,
                pendingEvents: pair.stream
            )
            if case .controlling = await coordinator.currentState() {
                statusMessage = "Controlling \(deviceName(targetDisplay.deviceID))"
            } else {
                finishPendingActivationInput()
                capture.setSuppressionEnabled(false)
            }
        }
    }

    private func upsert(
        _ device: DeviceDescriptor,
        capabilitiesAreAuthoritative: Bool
    ) {
        guard var workspace else { return }
        if let index = workspace.devices.firstIndex(where: { $0.id == device.id }) {
            workspace.updateDevice(WorkspaceReplicaMerger.mergeDevice(
                workspace.devices[index],
                with: device,
                capabilitiesAreAuthoritative: capabilitiesAreAuthoritative
            ))
        } else {
            workspace.devices.append(device)
        }
        persistAndBroadcastLocally(workspace)
    }

    private func persistAndBroadcastLocally(_ snapshot: WorkspaceSnapshot) {
        do {
            try workspaceStore.save(snapshot)
            workspace = snapshot
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func broadcast(_ envelope: ControlEnvelope) async {
        guard let workspace else { return }
        for device in workspace.devices where device.id != localDeviceID {
            try? await transport.send(envelope, to: device.id)
        }
    }

    private func deviceName(_ id: DeviceID) -> String {
        workspace?.devices.first(where: { $0.id == id })?.name ?? "Mac"
    }

    private func capabilities(of id: DeviceID) -> Set<DeviceCapability> {
        workspace?.devices.first(where: { $0.id == id })?.capabilities ?? []
    }

    private var routableDeviceIDs: Set<DeviceID> {
        ControlRoutingPolicy.availableDeviceIDs(
            connectedDeviceIDs: connectedDevices,
            devices: workspace?.devices ?? []
        )
    }

    private func refreshLocalDisplays() {
        guard var workspace, let index = workspace.devices.firstIndex(where: { $0.id == localDeviceID }) else { return }
        var current = localDevice
        current.peerAddresses = WorkspaceReplicaMerger.mergeAddresses(
            workspace.devices[index].peerAddresses,
            current.peerAddresses
        )
        guard workspace.devices[index] != current else { return }
        workspace.updateDevice(current)
        persistAndBroadcast(workspace)
    }

    private static func loadDeviceID() -> DeviceID {
        let key = "UniSpace.DeviceID"
        if let stored = UserDefaults.standard.string(forKey: key), let uuid = UUID(uuidString: stored) {
            return DeviceID(rawValue: uuid)
        }
        let id = DeviceID()
        UserDefaults.standard.set(id.rawValue.uuidString, forKey: key)
        return id
    }
}
