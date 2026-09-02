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
    private let qosTransport: QoSFileTransferTransport?
    private let checkpointStore: CheckpointingTransferStore?
    private let streamingSource: StreamingPersistentFileSourceProvider?
    private let eventPump = FileTransferEventPump()
    private var records: [TransferID: FileTransferSnapshot] = [:]
    private var bindingCancellable: AnyCancellable?
    private var contextTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var configuredWorkspace: ContinuityWorkspaceConfiguration?
    private var cachedWorkspaceKey: (WorkspaceID, UInt64, Data)?
    private var reportedConfigurationFailureWorkspaceID: WorkspaceID?
    private var controlConnectedDeviceIDs = Set<DeviceID>()

    init(
        trustStore: KeychainTrustStore = KeychainTrustStore(),
        coordinator: FileTransferCoordinator? = nil
    ) {
        self.trustStore = trustStore
        if let coordinator {
            self.coordinator = coordinator
            qosTransport = nil
            checkpointStore = nil
            streamingSource = nil
        } else {
            let pasteboard = SystemFilePasteboard()
            let qosTransport = QoSFileTransferTransport(
                underlying: NetworkFileTransferTransport()
            )
            let checkpointStore = CheckpointingTransferStore()
            let streamingSource = StreamingPersistentFileSourceProvider()
            self.qosTransport = qosTransport
            self.checkpointStore = checkpointStore
            self.streamingSource = streamingSource
            self.coordinator = FileTransferCoordinator(
                transport: qosTransport,
                store: checkpointStore,
                sourceProvider: streamingSource,
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
        contextTask?.cancel()
        eventTask?.cancel()
    }

    var activeTransferCount: Int {
        transfers.filter(\.isActive).count
    }

    var effectiveDestinationID: DeviceID? {
        FileTransferDestinationResolver.resolve(
            selectedDeviceID: selectedDestinationID,
            continuityTargetID: nil,
            candidates: candidateDevices,
            connectedDeviceIDs: connectedDeviceIDs.intersection(controlConnectedDeviceIDs)
        )
    }

    func bind(to appModel: AppModel) {
        guard bindingCancellable == nil else { return }
        startEventObservation()
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

    func stop() {
        bindingCancellable?.cancel()
        bindingCancellable = nil
        contextTask?.cancel()
        contextTask = nil
        eventTask?.cancel()
        eventTask = nil
        configuredWorkspace = nil
        reportedConfigurationFailureWorkspaceID = nil
        cachedWorkspaceKey = nil
        candidateDevices = []
        knownDevices = []
        connectedDeviceIDs = []
        controlConnectedDeviceIDs = []
        let coordinator = self.coordinator
        let checkpointStore = self.checkpointStore
        let streamingSource = self.streamingSource
        let eventPump = self.eventPump
        Task {
            await eventPump.reset()
            await coordinator.stop()
            await checkpointStore?.suspendAll()
            await streamingSource?.suspendAll()
        }
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
        let eventPump = self.eventPump
        eventTask = Task { [weak self, coordinator, eventPump] in
            let events = await coordinator.events()
            await eventPump.run(events: events) { [weak self] event in
                self?.receiveImmediately(event)
            }
        }
    }

    private func refreshContext(
        _ context: ContinuityContextSnapshot,
        localDevice: DeviceDescriptor
    ) async {
        let devices = context.workspace?.devices ?? []
        let candidates = devices
            .filter {
                $0.id != localDevice.id &&
                    context.connectedDeviceIDs.contains($0.id) &&
                    $0.capabilities.contains(.fileTransferV1)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        controlConnectedDeviceIDs = context.connectedDeviceIDs
        if knownDevices != devices { knownDevices = devices }
        if candidateDevices != candidates { candidateDevices = candidates }
        await updateTransferQoS(from: context)

        if let selectedDestinationID,
           !candidates.contains(where: { $0.id == selectedDestinationID }) {
            self.selectedDestinationID = nil
        }
        let continuityTarget = continuityTargetID(
            context: context,
            localDeviceID: localDevice.id
        )
        if selectedDestinationID == nil, let inferred = continuityTarget {
            selectedDestinationID = inferred
        }

        guard let workspace = context.workspace else {
            reportedConfigurationFailureWorkspaceID = nil
            if configuredWorkspace != nil {
                configuredWorkspace = nil
                records.removeAll()
                transfers = []
                await coordinator.stop()
                await checkpointStore?.suspendAll()
                await streamingSource?.suspendAll()
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
                throw FileTransferFailureCode.permissionFailure
            }
            let configuration = ContinuityWorkspaceConfiguration(
                workspace: workspace,
                localDevice: localDevice,
                key: key,
                capabilities: [.fileTransferV1]
            )
            if configuration != configuredWorkspace {
                try await coordinator.start(
                    localDevice: configuration.localDevice,
                    workspace: configuration.workspace,
                    key: configuration.key
                )
                configuredWorkspace = configuration
                reportedConfigurationFailureWorkspaceID = nil
                let recovered = await coordinator.snapshots()
                records = Dictionary(uniqueKeysWithValues: recovered.map { ($0.id, $0) })
                sortTransfers()
            }
            let destination = FileTransferDestinationResolver.resolve(
                selectedDeviceID: selectedDestinationID,
                continuityTargetID: continuityTarget,
                candidates: candidateDevices,
                connectedDeviceIDs: context.connectedDeviceIDs
            )
            await coordinator.setAutomaticDestination(destination)
        } catch {
            configuredWorkspace = nil
            await coordinator.stop()
            await checkpointStore?.suspendAll()
            await streamingSource?.suspendAll()
            if reportedConfigurationFailureWorkspaceID != workspace.id {
                reportedConfigurationFailureWorkspaceID = workspace.id
                lastError = userMessage(for: error)
            }
        }
    }

    private func updateTransferQoS(from context: ContinuityContextSnapshot) async {
        guard let qosTransport else { return }
        let active = context.controlSession.protectsInputLatency
        let peer = active ? context.controlSession.peerID : nil
        let latency = context.controlSession.latencyMilliseconds
        await qosTransport.updateControlQuality(FileTransferControlQuality(
            isControlActive: active,
            activePeerID: peer,
            latencyMilliseconds: latency
        ))
    }

    private func continuityTargetID(
        context: ContinuityContextSnapshot,
        localDeviceID: DeviceID
    ) -> DeviceID? {
        ContinuityDestinationResolver.resolve(
            localDeviceID: localDeviceID,
            controllerID: context.controllerID,
            controlSession: context.controlSession,
            devices: context.workspace?.devices ?? [],
            connectedDeviceIDs: context.connectedDeviceIDs,
            requiredCapabilities: [.fileTransferV1]
        )
    }

    private func receiveImmediately(_ event: FileTransferCoordinatorEvent) {
        switch event {
        case let .resync(snapshots):
            records = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        case let .snapshot(snapshot):
            records[snapshot.id] = snapshot
        case let .removed(transferID):
            records.removeValue(forKey: transferID)
        case let .connections(deviceIDs):
            if connectedDeviceIDs != deviceIDs { connectedDeviceIDs = deviceIDs }
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

/// Consumes the high-frequency coordinator stream away from the main actor and
/// retains only the newest byte-progress snapshot per transfer. State changes,
/// failures, completion, cancellation, and removal bypass the throttle.
private actor FileTransferEventPump {
    typealias Sink = @MainActor @Sendable (FileTransferCoordinatorEvent) -> Void

    private let interval: Duration
    private var latestSnapshots: [TransferID: FileTransferSnapshot] = [:]
    private var pendingSnapshots: [TransferID: FileTransferSnapshot] = [:]
    private var flushTasks: [TransferID: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0

    init(interval: Duration = .milliseconds(100)) {
        self.interval = interval
    }

    func run(
        events: AsyncStream<FileTransferCoordinatorEvent>,
        sink: @escaping Sink
    ) async {
        let activeGeneration = generation
        for await event in events {
            guard !Task.isCancelled, activeGeneration == generation else { return }
            await consume(event, sink: sink, generation: activeGeneration)
        }
    }

    func reset() {
        generation &+= 1
        latestSnapshots.removeAll(keepingCapacity: true)
        pendingSnapshots.removeAll(keepingCapacity: true)
        flushTasks.values.forEach { $0.cancel() }
        flushTasks.removeAll(keepingCapacity: true)
    }

    private func consume(
        _ event: FileTransferCoordinatorEvent,
        sink: @escaping Sink,
        generation activeGeneration: UInt64
    ) async {
        switch event {
        case .resync:
            latestSnapshots.removeAll(keepingCapacity: true)
            pendingSnapshots.removeAll(keepingCapacity: true)
            flushTasks.values.forEach { $0.cancel() }
            flushTasks.removeAll(keepingCapacity: true)
            await sink(event)
        case let .removed(transferID):
            latestSnapshots.removeValue(forKey: transferID)
            pendingSnapshots.removeValue(forKey: transferID)
            flushTasks.removeValue(forKey: transferID)?.cancel()
            await sink(event)
        case .connections:
            await sink(event)
        case let .snapshot(snapshot):
            let previous = latestSnapshots[snapshot.id]
            latestSnapshots[snapshot.id] = snapshot
            let isStateChange = previous == nil
                || previous?.state != snapshot.state
                || previous?.failureCode != snapshot.failureCode
                || previous?.stagedURLs != snapshot.stagedURLs
                || snapshot.state.isTerminal
            if isStateChange {
                pendingSnapshots.removeValue(forKey: snapshot.id)
                flushTasks.removeValue(forKey: snapshot.id)?.cancel()
                await sink(event)
                return
            }
            pendingSnapshots[snapshot.id] = snapshot
            guard flushTasks[snapshot.id] == nil else { return }
            let transferID = snapshot.id
            let interval = self.interval
            flushTasks[transferID] = Task { [weak self] in
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.flush(
                    transferID,
                    sink: sink,
                    generation: activeGeneration
                )
            }
        }
    }

    private func flush(
        _ transferID: TransferID,
        sink: @escaping Sink,
        generation activeGeneration: UInt64
    ) async {
        flushTasks.removeValue(forKey: transferID)
        guard activeGeneration == generation,
              let snapshot = pendingSnapshots.removeValue(forKey: transferID) else { return }
        await sink(.snapshot(snapshot))
    }
}
