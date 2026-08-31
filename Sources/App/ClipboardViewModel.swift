import Combine
import Foundation
import UniSpaceApplication
import UniSpaceDomain
import UniSpaceInfrastructure

@MainActor
final class ClipboardViewModel: ObservableObject {
    private static let sharingPreferenceKey = "continuity.clipboardSharingEnabled"

    @Published private(set) var connectedDeviceIDs = Set<DeviceID>()
    @Published private(set) var knownDevices: [DeviceDescriptor] = []
    @Published private(set) var activeDestinationID: DeviceID?
    @Published private(set) var lastError: String?
    @Published var sharingEnabled: Bool

    private let defaults: UserDefaults
    private let trustStore: KeychainTrustStore
    private let coordinator: ClipboardCoordinator
    private var bindingCancellable: AnyCancellable?
    private var contextTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var configuredWorkspace: ContinuityWorkspaceConfiguration?
    private var cachedWorkspaceKey: (WorkspaceID, UInt64, Data)?
    private var reportedConfigurationFailureWorkspaceID: WorkspaceID?

    init(
        defaults: UserDefaults = .standard,
        trustStore: KeychainTrustStore = KeychainTrustStore(),
        coordinator: ClipboardCoordinator? = nil
    ) {
        self.defaults = defaults
        self.trustStore = trustStore
        sharingEnabled = defaults.bool(forKey: Self.sharingPreferenceKey)
        self.coordinator = coordinator ?? ClipboardCoordinator(
            transport: NetworkClipboardTransport(),
            clipboard: SystemClipboardService()
        )
    }

    deinit {
        contextTask?.cancel()
        connectionTask?.cancel()
    }

    var activeDestinationName: String? {
        guard let activeDestinationID else { return nil }
        return knownDevices.first(where: { $0.id == activeDestinationID })?.name
    }

    var isDestinationConnected: Bool {
        guard let activeDestinationID else { return false }
        return connectedDeviceIDs.contains(activeDestinationID)
    }

    var statusText: String {
        guard sharingEnabled else { return "Clipboard sharing is off" }
        guard let name = activeDestinationName else {
            return "Move control to a compatible device to share its clipboard"
        }
        return isDestinationConnected
            ? "Sharing text and links with \(name)"
            : "Waiting for \(name)’s encrypted clipboard connection"
    }

    func bind(to appModel: AppModel) {
        guard bindingCancellable == nil else { return }
        startConnectionObservation()
        bindingCancellable = appModel.continuityContextPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self, weak appModel] context in
                Task { @MainActor [weak self, weak appModel] in
                    guard let self, let appModel else { return }
                    self.contextTask?.cancel()
                    let localDevice = appModel.localDevice
                    self.contextTask = Task { @MainActor [weak self] in
                        await self?.refreshContext(context, localDevice: localDevice)
                    }
                }
            }
    }

    func setSharingEnabled(_ enabled: Bool) {
        sharingEnabled = enabled
        defaults.set(enabled, forKey: Self.sharingPreferenceKey)
        let coordinator = self.coordinator
        Task { await coordinator.setSharingEnabled(enabled) }
    }

    func dismissError() { lastError = nil }

    func stop() {
        bindingCancellable?.cancel()
        bindingCancellable = nil
        contextTask?.cancel()
        contextTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        configuredWorkspace = nil
        cachedWorkspaceKey = nil
        reportedConfigurationFailureWorkspaceID = nil
        connectedDeviceIDs = []
        activeDestinationID = nil
        knownDevices = []
        let coordinator = self.coordinator
        Task { await coordinator.stop() }
    }

    private func startConnectionObservation() {
        guard connectionTask == nil else { return }
        let coordinator = self.coordinator
        connectionTask = Task { [weak self, coordinator] in
            let events = await coordinator.connectionEvents()
            for await deviceIDs in events {
                guard !Task.isCancelled, let self else { return }
                if self.connectedDeviceIDs != deviceIDs {
                    self.connectedDeviceIDs = deviceIDs
                }
            }
        }
    }

    private func refreshContext(
        _ context: ContinuityContextSnapshot,
        localDevice: DeviceDescriptor
    ) async {
        let devices = context.workspace?.devices ?? []
        if knownDevices != devices { knownDevices = devices }

        guard let workspace = context.workspace else {
            reportedConfigurationFailureWorkspaceID = nil
            if configuredWorkspace != nil {
                configuredWorkspace = nil
                activeDestinationID = nil
                connectedDeviceIDs = []
                await coordinator.stop()
            }
            cachedWorkspaceKey = nil
            return
        }

        do {
            let key: Data
            if let cachedWorkspaceKey,
               cachedWorkspaceKey.0 == workspace.id,
               cachedWorkspaceKey.1 == context.workspaceKeyRevision {
                key = cachedWorkspaceKey.2
            } else if let loaded = try trustStore.workspaceKey(for: workspace.id) {
                key = loaded
                cachedWorkspaceKey = (workspace.id, context.workspaceKeyRevision, loaded)
            } else {
                throw ClipboardProtocolError.workspaceMismatch
            }
            let configuration = ContinuityWorkspaceConfiguration(
                workspace: workspace,
                localDevice: localDevice,
                key: key,
                capabilities: [.clipboardTextV1, .clipboardURLV1]
            )
            if configuration != configuredWorkspace {
                try await coordinator.start(
                    localDevice: configuration.localDevice,
                    workspace: configuration.workspace,
                    key: configuration.key
                )
                await coordinator.setSharingEnabled(sharingEnabled)
                configuredWorkspace = configuration
                reportedConfigurationFailureWorkspaceID = nil
            }
        } catch {
            configuredWorkspace = nil
            connectedDeviceIDs = []
            await coordinator.stop()
            if reportedConfigurationFailureWorkspaceID != workspace.id {
                reportedConfigurationFailureWorkspaceID = workspace.id
                lastError = "UniSpace could not start its encrypted clipboard connection."
            }
            return
        }

        let inferredFromApp = inferredDestination(
            context: context,
            localDeviceID: localDevice.id
        )
        let coordinatorDestination = await coordinator.automaticDestinationDeviceID()
        let inferred = inferredFromApp ?? coordinatorDestination
        if activeDestinationID != inferred {
            activeDestinationID = inferred
            await coordinator.setAutomaticDestination(inferred)
        }
    }

    private func inferredDestination(
        context: ContinuityContextSnapshot,
        localDeviceID: DeviceID
    ) -> DeviceID? {
        let target = context.controllerID != localDeviceID
            ? context.controllerID
            : context.controlSession.peerID
        if let target,
           context.connectedDeviceIDs.contains(target),
           connectedDeviceIDs.contains(target) {
            return target
        }
        let remoteConnected = connectedDeviceIDs
            .intersection(context.connectedDeviceIDs)
            .filter { $0 != localDeviceID }
        return remoteConnected.count == 1 ? remoteConnected.first : nil
    }
}
