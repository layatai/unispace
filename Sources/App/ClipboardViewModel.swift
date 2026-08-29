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
    private var bindingTask: Task<Void, Never>?
    private var configuredWorkspace: ContinuityWorkspaceConfiguration?

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

    deinit { bindingTask?.cancel() }

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
        guard bindingTask == nil else { return }
        bindingTask = Task { [weak self, weak appModel] in
            while !Task.isCancelled {
                guard let self, let appModel else { return }
                await self.refreshContext(from: appModel)
                try? await Task.sleep(for: .milliseconds(350))
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
        bindingTask?.cancel()
        bindingTask = nil
        configuredWorkspace = nil
        connectedDeviceIDs = []
        activeDestinationID = nil
        knownDevices = []
        let coordinator = self.coordinator
        Task { await coordinator.stop() }
    }

    private func refreshContext(from appModel: AppModel) async {
        knownDevices = appModel.devices
        connectedDeviceIDs = await coordinator.connectedDeviceIDs()

        guard let workspace = appModel.workspace else {
            if configuredWorkspace != nil {
                configuredWorkspace = nil
                activeDestinationID = nil
                connectedDeviceIDs = []
                await coordinator.stop()
            }
            return
        }

        do {
            guard let key = try trustStore.workspaceKey(for: workspace.id) else {
                throw ClipboardProtocolError.workspaceMismatch
            }
            let configuration = ContinuityWorkspaceConfiguration(
                workspace: workspace,
                localDevice: appModel.localDevice,
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
            }
        } catch {
            configuredWorkspace = nil
            connectedDeviceIDs = []
            await coordinator.stop()
            lastError = "UniSpace could not start its encrypted clipboard connection."
            return
        }

        connectedDeviceIDs = await coordinator.connectedDeviceIDs()
        let inferred = inferredDestination(from: appModel)
        if activeDestinationID != inferred {
            activeDestinationID = inferred
            await coordinator.setAutomaticDestination(inferred)
        }
    }

    private func inferredDestination(from appModel: AppModel) -> DeviceID? {
        if let target = appModel.continuityTargetID,
           connectedDeviceIDs.contains(target) {
            return target
        }
        let remoteConnected = connectedDeviceIDs.filter { $0 != appModel.localDeviceID }
        return remoteConnected.count == 1 ? remoteConnected.first : nil
    }
}
