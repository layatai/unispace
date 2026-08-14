import AppKit
import Combine
import Foundation
import UniSpaceApplication
import UniSpaceDomain
import UniSpaceInfrastructure

@MainActor
final class FileTransferViewModel: ObservableObject {
    @Published private(set) var transfers: [FileTransferSnapshot] = []
    @Published private(set) var connectedDeviceIDs = Set<DeviceID>()
    @Published private(set) var candidateDevices: [DeviceDescriptor] = []
    @Published private(set) var knownDevices: [DeviceDescriptor] = []
    @Published var selectedDestinationID: DeviceID?
    @Published var lastError: String?

    private let trustStore: KeychainTrustStore
    private let coordinator: FileTransferCoordinator
    private var records: [TransferID: FileTransferSnapshot] = [:]
    private var bindingTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var configuredWorkspaceID: WorkspaceID?

    init(
        trustStore: KeychainTrustStore = KeychainTrustStore(),
        coordinator: FileTransferCoordinator? = nil
    ) {
        self.trustStore = trustStore
        if let coordinator {
            self.coordinator = coordinator
        } else {
            let pasteboard = SystemFilePasteboard()
            self.coordinator = FileTransferCoordinator(
                transport: NetworkFileTransferTransport(),
                store: SandboxTransferStore(),
                sourceProvider: SystemFileSourceProvider(),
                pasteboard: pasteboard
            )
        }

        if ProcessInfo.processInfo.arguments.contains("--ui-testing-transfers") {
            let peer = DeviceID()
            let transferID = TransferID()
            records[transferID] = FileTransferSnapshot(
                id: transferID,
                direction: .incoming,
                peerDeviceID: peer,
                displayName: "Quarterly Report.pdf",
                fileCount: 1,
                totalByteCount: 8_000_000,
                transferredByteCount: 3_200_000,
                state: .transferring,
                createdAt: Date()
            )
            transfers = Array(records.values)
        }
    }

    deinit {
        bindingTask?.cancel()
        eventTask?.cancel()
    }

    var activeTransferCount: Int {
        transfers.filter(\.isActive).count
    }

    var effectiveDestinationID: DeviceID? {
        if let selectedDestinationID,
           connectedDeviceIDs.contains(selectedDestinationID) {
            return selectedDestinationID
        }
        return candidateDevices.first(where: {
            connectedDeviceIDs.contains($0.id)
        })?.id
    }

    func bind(to appModel: AppModel) {
        guard bindingTask == nil else { return }
        startEventObservation()
        bindingTask = Task { [weak self, weak appModel] in
            while !Task.isCancelled {
                guard let self, let appModel else { return }
                await self.refreshContext(from: appModel)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        bindingTask?.cancel()
        bindingTask = nil
        configuredWorkspaceID = nil
        candidateDevices = []
        knownDevices = []
        connectedDeviceIDs = []
        let coordinator = self.coordinator
        Task { await coordinator.stop() }
    }

    func chooseFiles() {
        guard let destination = effectiveDestinationID else {
            lastError = FileTransferCoordinatorError.noDestination.localizedDescription
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Send Files with UniSpace"
        panel.prompt = "Send"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        guard panel.runModal() == .OK else { return }
        send(panel.urls, to: destination)
    }

    func send(_ urls: [URL], to destination: DeviceID? = nil) {
        guard let target = destination ?? effectiveDestinationID else {
            lastError = FileTransferCoordinatorError.noDestination.localizedDescription
            return
        }
        let coordinator = self.coordinator
        Task {
            do {
                _ = try await coordinator.sendFiles(urls, to: target)
            } catch {
                await MainActor.run { self.lastError = self.userMessage(for: error) }
            }
        }
    }

    func cancel(_ transferID: TransferID) {
        let coordinator = self.coordinator
        Task { await coordinator.cancel(transferID) }
    }

    func retry(_ transferID: TransferID) {
        let coordinator = self.coordinator
        Task {
            do {
                try await coordinator.retry(transferID)
            } catch {
                await MainActor.run { self.lastError = self.userMessage(for: error) }
            }
        }
    }

    func remove(_ transferID: TransferID) {
        let coordinator = self.coordinator
        Task { await coordinator.remove(transferID) }
    }

    func clearCompleted() {
        let coordinator = self.coordinator
        Task { await coordinator.clearCompleted() }
    }

    func reveal(_ snapshot: FileTransferSnapshot) {
        guard !snapshot.stagedURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(snapshot.stagedURLs)
    }

    func export(_ snapshot: FileTransferSnapshot) {
        guard !snapshot.stagedURLs.isEmpty else { return }
        if snapshot.stagedURLs.count == 1, let source = snapshot.stagedURLs.first {
            let panel = NSSavePanel()
            panel.title = "Save Received File"
            panel.nameFieldStringValue = source.lastPathComponent
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                lastError = "UniSpace could not save the received file."
            }
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for Received Files"
        panel.prompt = "Save Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            for source in snapshot.stagedURLs {
                let destination = uniqueDestination(
                    directory.appendingPathComponent(source.lastPathComponent)
                )
                try FileManager.default.copyItem(at: source, to: destination)
            }
        } catch {
            lastError = "UniSpace could not save one or more received files."
        }
    }

    func dismissError() {
        lastError = nil
    }

    func deviceName(_ id: DeviceID) -> String {
        knownDevices.first(where: { $0.id == id })?.name ?? "Mac"
    }

    private func startEventObservation() {
        guard eventTask == nil else { return }
        let coordinator = self.coordinator
        eventTask = Task { [weak self, coordinator] in
            let events = await coordinator.events()
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                self.receive(event)
            }
        }
    }

    private func refreshContext(from appModel: AppModel) async {
        knownDevices = appModel.devices
        candidateDevices = appModel.continuityCandidateDevices
        connectedDeviceIDs = await coordinator.connectedDeviceIDs()

        if let selectedDestinationID,
           !knownDevices.contains(where: { $0.id == selectedDestinationID }) {
            self.selectedDestinationID = nil
        }
        if selectedDestinationID == nil, let inferred = appModel.continuityTargetID {
            selectedDestinationID = inferred
        }
        await coordinator.setAutomaticDestination(selectedDestinationID ?? appModel.continuityTargetID)

        guard let workspace = appModel.workspace else {
            if configuredWorkspaceID != nil {
                configuredWorkspaceID = nil
                records.removeAll()
                transfers = []
                await coordinator.stop()
            }
            return
        }
        guard configuredWorkspaceID != workspace.id else { return }

        do {
            guard let key = try trustStore.workspaceKey(for: workspace.id) else {
                throw FileTransferFailureCode.permissionFailure
            }
            var local = appModel.localDevice
            local.capabilities.insert(.fileTransferV1)
            var transferWorkspace = workspace
            transferWorkspace.updateDevice(local)
            try await coordinator.start(
                localDevice: local,
                workspace: transferWorkspace,
                key: key
            )
            configuredWorkspaceID = workspace.id
            let recovered = await coordinator.snapshots()
            records = Dictionary(uniqueKeysWithValues: recovered.map { ($0.id, $0) })
            sortTransfers()
        } catch {
            configuredWorkspaceID = nil
            lastError = userMessage(for: error)
        }
    }

    private func receive(_ event: FileTransferCoordinatorEvent) {
        switch event {
        case let .snapshot(snapshot):
            records[snapshot.id] = snapshot
        case let .removed(transferID):
            records.removeValue(forKey: transferID)
        }
        sortTransfers()
    }

    private func sortTransfers() {
        transfers = records.values.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func uniqueDestination(_ requested: URL) -> URL {
        guard FileManager.default.fileExists(atPath: requested.path) else { return requested }
        let fileExtension = requested.pathExtension
        let base = requested.deletingPathExtension().lastPathComponent
        let directory = requested.deletingLastPathComponent()
        var index = 2
        while true {
            var name = "\(base) \(index)"
            if !fileExtension.isEmpty { name += ".\(fileExtension)" }
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func userMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        if let code = error as? FileTransferFailureCode {
            return message(for: code)
        }
        return "The file transfer could not be completed."
    }

    private func message(for code: FileTransferFailureCode) -> String {
        switch code {
        case .unsupportedPeer:
            "The selected Mac needs a newer UniSpace version for file transfer."
        case .transferRejected:
            "The destination Mac rejected the transfer."
        case .manifestInvalid:
            "One or more selected files are not safe to transfer."
        case .fileUnavailable:
            "A selected file is no longer available."
        case .sourceChanged:
            "A selected file changed during transfer. Copy it again and retry."
        case .invalidOffset, .protocolViolation:
            "The encrypted transfer session became inconsistent and was stopped."
        case .sizeLimitExceeded:
            "The selected files exceed UniSpace’s transfer limit."
        case .insufficientStorage:
            "The destination Mac does not have enough free storage."
        case .hashMismatch:
            "A received file failed its integrity check."
        case .contentChannelUnavailable:
            "The destination Mac’s file-transfer connection is unavailable."
        case .cancelled:
            "The transfer was cancelled."
        case .resumeRejected:
            "The transfer could not resume and must be started again."
        case .stagingFailure:
            "UniSpace could not stage the received files safely."
        case .permissionFailure:
            "UniSpace could not read its trusted workspace key."
        case .timedOut:
            "The file transfer timed out."
        case .unknown:
            "The file transfer could not be completed."
        }
    }
}
