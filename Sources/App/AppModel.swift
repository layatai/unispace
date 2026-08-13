import AppKit
import Combine
import Foundation
import UniSpaceApplication
import UniSpaceDomain
import UniSpaceInfrastructure

@MainActor
final class AppModel: ObservableObject {
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
    @Published private(set) var currentControllerID: DeviceID?
    @Published private(set) var statusMessage = "Not configured"
    @Published var lastError: String?
    @Published private(set) var inputMonitoringPermission: PermissionState = .unknown
    @Published private(set) var postEventsPermission: PermissionState = .unknown
    @Published private(set) var launchAtLogin = false

    private let workspaceStore = FileWorkspaceStore()
    private let trustStore = KeychainTrustStore()
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
    private var screenChangeSubscription: AnyCancellable?
    private var currentEpoch: ControllerEpoch?
    private var lastBoundaryTime: UInt64 = 0

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
            if workspace != nil {
                setupState = .ready
                Task { await startTrustedNetwork(claimControl: false) }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    deinit {
        networkTask?.cancel()
    }

    var localDevice: DeviceDescriptor {
        DeviceDescriptor(
            id: localDeviceID,
            name: Host.current().localizedName ?? "Mac",
            displays: displayCatalog.currentDisplays(for: localDeviceID),
            peerAddresses: tailnetAddressProvider.currentAddresses()
        )
    }

    var tailnetAddresses: [PeerAddress] { tailnetAddressProvider.currentAddresses() }

    var devices: [DeviceDescriptor] { workspace?.devices ?? [] }
    var allDisplays: [DisplayDescriptor] { devices.flatMap(\.displays) }
    var isLocalController: Bool { currentControllerID == localDeviceID }

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
        pairing.startBrowsing()
        setupState = .browsing
        statusMessage = "Looking for UniSpace workspaces"
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
        connectedDevices = []
        currentControllerID = nil
        currentEpoch = nil
        lastBoundaryTime = 0
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
            currentEpoch = epoch
            currentControllerID = localDeviceID
            if var workspace, epoch.generation > workspace.generation {
                workspace.generation = epoch.generation
                persistAndBroadcastLocally(workspace)
            }
            await broadcast(ControlEnvelope(message: .controllerClaim(epoch)))
            statusMessage = "This Mac controls the workspace"
        }
    }

    func stopControlling() {
        Task {
            await coordinator?.deactivateCurrentSession()
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
            workspace.topology.links.removeAll {
                removedDisplays.contains($0.source.displayID) || removedDisplays.contains($0.destination.displayID)
            }
            let newKey = PairingCryptoSession.randomData(count: 32)
            for peer in workspace.devices where peer.id != localDeviceID && connectedDevices.contains(peer.id) {
                try? await transport.send(ControlEnvelope(message: .workspace(workspace)), to: peer.id)
                try? await transport.send(ControlEnvelope(message: .rotateWorkspaceKey(newKey)), to: peer.id)
            }
            do {
                try trustStore.storeWorkspaceKey(newKey, for: workspace.id)
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
                self?.statusMessage = "Confirm the code on both Macs"
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
                    statusMessage = setupState == .hostingPairing
                        ? "Visible to nearby Macs as \(localDevice.name)"
                        : "Searching the local network"
                case let .waiting(message):
                    statusMessage = "Waiting for local network access: \(message)"
                case let .failed(message):
                    lastError = "Local network discovery failed: \(message)"
                    setupState = workspace == nil ? .needsWorkspace : .ready
                }
            }
        }
    }

    private func completeJoin(snapshot: WorkspaceSnapshot, key: Data) {
        do {
            try trustStore.storeWorkspaceKey(key, for: snapshot.id)
            try workspaceStore.save(snapshot)
            workspace = snapshot
            setupState = .ready
            Task { await startTrustedNetwork(claimControl: false) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func completeHostPairing(snapshot: WorkspaceSnapshot) {
        var snapshot = snapshot
        if snapshot.topology.links.isEmpty,
           let localDisplay = snapshot.devices.first(where: { $0.id == localDeviceID })?.displays.first(where: \.isMain),
           let remoteDisplay = snapshot.devices.first(where: { $0.id != localDeviceID })?.displays.first(where: \.isMain) {
            snapshot.topology.connect(
                DisplayEndpoint(displayID: localDisplay.id, edge: .right),
                to: DisplayEndpoint(displayID: remoteDisplay.id, edge: .left)
            )
        }
        persistAndBroadcast(snapshot)
        setupState = .ready
        statusMessage = "Paired successfully"
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
            guard let key = try trustStore.workspaceKey(for: workspace.id) else { return }
            networkTask?.cancel()
            await transport.stop()
            let local = refreshedLocalDevice(in: workspace)
            guard let refreshedWorkspace = self.workspace else { return }
            try await transport.start(localDevice: local, workspace: refreshedWorkspace, key: key)
            coordinator = ControlSessionCoordinator(
                localDeviceID: localDeviceID,
                workspaceID: workspace.id,
                capture: capture,
                injector: injector,
                transport: transport,
                election: ControllerStateMachine(nextGeneration: workspace.generation + 1)
            )
            startCaptureIfPossible()
            networkTask = Task { [weak self] in
                guard let self else { return }
                for await event in transport.events() {
                    if Task.isCancelled { break }
                    await self.handlePeerEvent(event)
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
            current.peerAddresses = Self.mergedAddresses(
                updated.devices[index].peerAddresses,
                current.peerAddresses
            )
            updated.devices[index] = current
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
                Task { @MainActor [weak self] in await self?.handleCaptured(event) }
                return false
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleCaptured(_ event: InputEvent) async {
        guard let coordinator else { return }
        if case let .pointerMove(_, _, x, y) = event,
           isLocalController,
           case .idle = await coordinator.currentState(),
           let workspace,
           let transition = EdgeRouter.transition(
                x: x,
                y: y,
                localDeviceID: localDeviceID,
                devices: workspace.devices,
                topology: workspace.topology
           ), connectedDevices.contains(transition.targetDeviceID) {
            do {
                try await coordinator.activate(
                    target: transition.targetDeviceID,
                    displayID: transition.targetDisplayID,
                    entryEdge: transition.entryEdge,
                    normalizedPosition: transition.normalizedPosition
                )
                statusMessage = "Controlling \(deviceName(transition.targetDeviceID))"
            } catch {
                lastError = error.localizedDescription
            }
        }
        _ = await coordinator.handleCaptured(event)
    }

    private func handleInjectedPointer(x: Double, y: Double) async {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastBoundaryTime > 250_000_000,
              let coordinator,
              case let .receiving(_, source, sessionID) = await coordinator.currentState(),
              let workspace,
              let transition = EdgeRouter.transition(
                x: x,
                y: y,
                localDeviceID: localDeviceID,
                devices: workspace.devices,
                topology: workspace.topology
              ) else { return }
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
            upsert(device)
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
        case let .disconnected(deviceID):
            connectedDevices.remove(deviceID)
            await coordinator?.peerDisconnected(deviceID)
        case let .control(source, envelope):
            await handleControl(envelope.message, from: source)
        case let .input(source, frame):
            await coordinator?.handleIncoming(frame, from: source)
        case let .failure(_, message):
            statusMessage = message
        }
    }

    private func handleControl(_ message: ControlMessage, from source: DeviceID) async {
        switch message {
        case let .hello(device):
            upsert(device)
        case let .workspace(incoming):
            guard var workspace, incoming.id == workspace.id else { return }
            workspace.devices = incoming.devices.map { incomingDevice in
                guard let current = workspace.devices.first(where: { $0.id == incomingDevice.id }) else {
                    return incomingDevice
                }
                return Self.merging(current, with: incomingDevice)
            }
            workspace.topology = incoming.topology
            workspace.generation = max(workspace.generation, incoming.generation)
            if !workspace.devices.contains(where: { $0.id == localDeviceID }) {
                workspace.devices.append(localDevice)
            }
            persistAndBroadcastLocally(workspace)
        case let .controllerClaim(epoch):
            currentEpoch = max(currentEpoch ?? epoch, epoch)
            currentControllerID = currentEpoch?.controllerID
            if var workspace, epoch.generation > workspace.generation {
                workspace.generation = epoch.generation
                persistAndBroadcastLocally(workspace)
            }
            await coordinator?.observeControllerClaim(epoch)
            statusMessage = currentControllerID == localDeviceID ? "This Mac controls the workspace" : "Receiver ready"
        case let .activate(activation):
            let display = workspace?.devices.flatMap(\.displays).first { $0.id == activation.targetDisplayID }
            await coordinator?.receiveActivation(activation, from: source, targetDisplay: display)
            statusMessage = "Controlled by \(deviceName(source))"
        case .deactivate, .releaseAll:
            await coordinator?.deactivateCurrentSession()
            statusMessage = isLocalController ? "Controller ready" : "Receiver ready"
        case let .boundaryCrossed(sessionID, displayID, edge, normalizedPosition):
            await handleBoundaryCrossed(
                from: source,
                sessionID: sessionID,
                displayID: displayID,
                edge: edge,
                normalizedPosition: normalizedPosition
            )
        case let .heartbeat(sessionID, _):
            await coordinator?.receiveHeartbeat(sessionID: sessionID, from: source)
        case let .rotateWorkspaceKey(newKey):
            guard let workspace else { return }
            do {
                try trustStore.storeWorkspaceKey(newKey, for: workspace.id)
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
        guard isLocalController, let workspace,
              let destination = workspace.topology.destination(from: displayID, edge: edge),
              let targetDisplay = workspace.devices.flatMap(\.displays).first(where: { $0.id == destination.displayID }) else { return }
        await coordinator?.deactivateCurrentSession()
        if targetDisplay.deviceID == localDeviceID {
            injector.activate(on: targetDisplay, enteringFrom: destination.edge, normalizedPosition: normalizedPosition)
            statusMessage = "Controller ready"
        } else {
            try? await coordinator?.activate(
                target: targetDisplay.deviceID,
                displayID: targetDisplay.id,
                entryEdge: destination.edge,
                normalizedPosition: normalizedPosition
            )
            statusMessage = "Controlling \(deviceName(targetDisplay.deviceID))"
        }
    }

    private func upsert(_ device: DeviceDescriptor) {
        guard var workspace else { return }
        if let index = workspace.devices.firstIndex(where: { $0.id == device.id }) {
            workspace.devices[index] = Self.merging(workspace.devices[index], with: device)
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

    private func refreshLocalDisplays() {
        guard var workspace, let index = workspace.devices.firstIndex(where: { $0.id == localDeviceID }) else { return }
        let current = localDevice
        guard workspace.devices[index] != current else { return }
        workspace.devices[index] = current
        persistAndBroadcast(workspace)
    }

    private static func merging(_ current: DeviceDescriptor, with incoming: DeviceDescriptor) -> DeviceDescriptor {
        var merged = incoming
        if merged.displays.isEmpty { merged.displays = current.displays }
        merged.peerAddresses = mergedAddresses(current.peerAddresses, incoming.peerAddresses)
        return merged
    }

    private static func mergedAddresses(_ first: [PeerAddress], _ second: [PeerAddress]) -> [PeerAddress] {
        Array(Set(first + second)).sorted { $0.host < $1.host }
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
