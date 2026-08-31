import Foundation
import UniSpaceDomain

public actor FileTransferCoordinator {
    private struct Record: Sendable {
        let manifest: TransferManifest
        let direction: FileTransferDirection
        let peerDeviceID: DeviceID
        var state: FileTransferState
        var verifiedOffsets: [TransferEntryID: UInt64]
        var failureCode: FileTransferFailureCode?
        var completedAt: Date?
        var stagedURLs: [URL]

        var transferredByteCount: UInt64 {
            manifest.entries.reduce(0) { partial, entry in
                let offset = min(verifiedOffsets[entry.id, default: 0], entry.byteCount)
                let (sum, overflow) = partial.addingReportingOverflow(offset)
                return overflow ? UInt64.max : sum
            }
        }

        var snapshot: FileTransferSnapshot {
            FileTransferSnapshot(
                id: manifest.transferID,
                direction: direction,
                peerDeviceID: peerDeviceID,
                displayName: manifest.displayName,
                fileCount: manifest.entries.count,
                totalByteCount: manifest.totalByteCount,
                transferredByteCount: transferredByteCount,
                state: state,
                failureCode: failureCode,
                createdAt: manifest.createdAt,
                completedAt: completedAt,
                stagedURLs: stagedURLs
            )
        }
    }

    private let transport: any FileTransferTransport
    private let store: any TransferStore
    private let sourceProvider: any FileSourceProvider
    private let pasteboard: any FilePasteboard
    private let limits: FileTransferLimits

    private let stream: AsyncStream<FileTransferCoordinatorEvent>
    private let continuation: AsyncStream<FileTransferCoordinatorEvent>.Continuation

    private var localDevice: DeviceDescriptor?
    private var workspace: WorkspaceSnapshot?
    private var records: [TransferID: Record] = [:]
    private var connectedPeers = Set<DeviceID>()
    private var automaticDestination: DeviceID?
    private var transferTasks: [TransferID: Task<Void, Never>] = [:]
    private var transferTaskTokens: [TransferID: UUID] = [:]
    private var transportTask: Task<Void, Never>?
    private var pasteboardTask: Task<Void, Never>?
    private var lastPasteboardChangeCount: Int?
    private var pendingPasteboardSelection: PasteboardFileSelection?
    private var started = false

    public init(
        transport: any FileTransferTransport,
        store: any TransferStore,
        sourceProvider: any FileSourceProvider,
        pasteboard: any FilePasteboard,
        limits: FileTransferLimits = .default
    ) {
        self.transport = transport
        self.store = store
        self.sourceProvider = sourceProvider
        self.pasteboard = pasteboard
        self.limits = limits
        var captured: AsyncStream<FileTransferCoordinatorEvent>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(128)) { captured = $0 }
        continuation = captured!
    }

    deinit {
        transportTask?.cancel()
        pasteboardTask?.cancel()
        transferTasks.values.forEach { $0.cancel() }
        continuation.finish()
    }

    public func events() -> AsyncStream<FileTransferCoordinatorEvent> { stream }

    public func snapshots() -> [FileTransferSnapshot] {
        records.values.map(\.snapshot).sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.createdAt > rhs.createdAt
        }
    }

    public func start(
        localDevice: DeviceDescriptor,
        workspace: WorkspaceSnapshot,
        key: Data
    ) async throws {
        if started { await stop() }
        started = true
        self.localDevice = localDevice
        self.workspace = workspace
        connectedPeers.removeAll()
        automaticDestination = nil
        records.removeAll()
        lastPasteboardChangeCount = nil
        pendingPasteboardSelection = nil

        await store.removeExpired(now: Date(), limits: limits)
        try await recoverTransfers()
        startTransportObservationIfNeeded()
        await startPasteboardObservationIfNeeded()
        try await transport.start(localDevice: localDevice, workspace: workspace, key: key)
    }

    public func stop() async {
        started = false
        transferTasks.values.forEach { $0.cancel() }
        transferTasks.removeAll()
        transferTaskTokens.removeAll()
        connectedPeers.removeAll()
        automaticDestination = nil
        pendingPasteboardSelection = nil
        await store.suspendAll()
        await sourceProvider.suspendAll()
        await transport.stop()
    }

    private func startTransportObservationIfNeeded() {
        guard transportTask == nil else { return }
        let transport = self.transport
        transportTask = Task { [weak self, transport] in
            for await event in transport.events() {
                guard !Task.isCancelled else { break }
                await self?.handleTransportEvent(event)
            }
        }
    }

    private func startPasteboardObservationIfNeeded() async {
        guard pasteboardTask == nil else { return }
        let pasteboardEvents = await pasteboard.events()
        pasteboardTask = Task { [weak self] in
            for await selection in pasteboardEvents {
                guard !Task.isCancelled else { break }
                await self?.handlePasteboardSelection(selection)
            }
        }
    }

    public func setAutomaticDestination(_ deviceID: DeviceID?) async {
        guard deviceID != localDevice?.id else {
            automaticDestination = nil
            return
        }
        automaticDestination = deviceID
        await offerPendingPasteboardSelectionIfPossible()
    }

    public func connectedDeviceIDs() -> Set<DeviceID> { connectedPeers }

    @discardableResult
    public func sendFiles(
        _ urls: [URL],
        to destinationDeviceID: DeviceID? = nil
    ) async throws -> TransferID {
        guard let localDevice, let workspace else {
            throw FileTransferCoordinatorError.noDestination
        }
        guard !urls.isEmpty else { throw FileTransferProtocolError.emptyManifest }
        guard let destination = destinationDeviceID ?? automaticDestination,
              destination != localDevice.id else {
            throw FileTransferCoordinatorError.noDestination
        }
        guard connectedPeers.contains(destination) else {
            throw FileTransferCoordinatorError.peerUnavailable(destination)
        }
        guard !hasActiveTransfer(direction: .outgoing, peer: destination) else {
            throw FileTransferCoordinatorError.peerBusy(destination)
        }

        let transferID = TransferID()
        let prepared = try await sourceProvider.prepare(
            urls: urls,
            transferID: transferID,
            workspaceID: workspace.id,
            sourceDeviceID: localDevice.id,
            destinationDeviceID: destination,
            limits: limits
        )
        let manifest = try prepared.manifest.validated(limits: limits)
        records[transferID] = Record(
            manifest: manifest,
            direction: .outgoing,
            peerDeviceID: destination,
            state: .offered,
            verifiedOffsets: zeroOffsets(for: manifest),
            failureCode: nil,
            completedAt: nil,
            stagedURLs: []
        )
        emit(transferID)
        setState(.awaitingAcceptance, for: transferID)

        do {
            try await send(.offer(TransferOffer(manifest: manifest)), to: destination)
        } catch {
            setFailure(.contentChannelUnavailable, for: transferID)
            throw FileTransferCoordinatorError.peerUnavailable(destination)
        }
        return transferID
    }

    public func cancel(_ transferID: TransferID) async {
        guard var record = records[transferID], !record.state.isTerminal else { return }
        cancelTransferTask(transferID)
        try? await send(
            .cancellation(TransferCancellation(transferID: transferID)),
            to: record.peerDeviceID
        )
        if record.direction == .incoming {
            await store.cancel(transferID)
        } else {
            await sourceProvider.removeOutgoingTransfer(transferID)
        }
        record.state = .cancelled
        record.failureCode = .cancelled
        record.completedAt = Date()
        records[transferID] = record
        emit(transferID)
    }

    public func retry(_ transferID: TransferID) async throws {
        guard var record = records[transferID] else {
            throw FileTransferCoordinatorError.transferNotFound(transferID)
        }
        guard record.state == .failed || record.state == .paused else {
            throw FileTransferCoordinatorError.invalidState(record.state)
        }
        guard connectedPeers.contains(record.peerDeviceID) else {
            throw FileTransferCoordinatorError.peerUnavailable(record.peerDeviceID)
        }
        guard !hasActiveTransfer(
            direction: record.direction,
            peer: record.peerDeviceID,
            excluding: transferID
        ) else {
            throw FileTransferCoordinatorError.peerBusy(record.peerDeviceID)
        }
        record.failureCode = nil
        record.completedAt = nil
        records[transferID] = record

        switch record.direction {
        case .outgoing:
            setState(.awaitingAcceptance, for: transferID, enforceTransition: false)
            try await send(.offer(TransferOffer(manifest: record.manifest)), to: record.peerDeviceID)
        case .incoming:
            setState(.paused, for: transferID, enforceTransition: false)
            try await send(.resumeState(try await resumeState(for: record)), to: record.peerDeviceID)
        }
    }

    public func remove(_ transferID: TransferID) async {
        guard let record = records[transferID], record.state.isTerminal else { return }
        cancelTransferTask(transferID)
        if record.direction == .incoming {
            await store.remove(transferID)
        } else {
            await sourceProvider.removeOutgoingTransfer(transferID)
        }
        records.removeValue(forKey: transferID)
        yield(.removed(transferID))
    }

    public func clearCompleted() async {
        let removable = records.values
            .filter { $0.state.isTerminal }
            .map { $0.manifest.transferID }
        for transferID in removable { await remove(transferID) }
    }

    private func recoverTransfers() async throws {
        let incoming = try await store.recoverIncomingTransfers(limits: limits)
        for recovered in incoming {
            let manifest = try recovered.manifest.validated(limits: limits)
            records[manifest.transferID] = Record(
                manifest: manifest,
                direction: .incoming,
                peerDeviceID: manifest.sourceDeviceID,
                state: recovered.isCompleted ? .completed : .paused,
                verifiedOffsets: Dictionary(
                    uniqueKeysWithValues: recovered.offsets.map { ($0.entryID, $0.offset) }
                ),
                failureCode: nil,
                completedAt: recovered.isCompleted ? Date() : nil,
                stagedURLs: recovered.completedURLs
            )
            emit(manifest.transferID)
        }

        let outgoing = try await sourceProvider.recoverOutgoingTransfers(limits: limits)
        for prepared in outgoing where records[prepared.manifest.transferID] == nil {
            let manifest = try prepared.manifest.validated(limits: limits)
            records[manifest.transferID] = Record(
                manifest: manifest,
                direction: .outgoing,
                peerDeviceID: manifest.destinationDeviceID,
                state: .paused,
                verifiedOffsets: zeroOffsets(for: manifest),
                failureCode: nil,
                completedAt: nil,
                stagedURLs: []
            )
            emit(manifest.transferID)
        }
    }

    private func handlePasteboardSelection(_ selection: PasteboardFileSelection) async {
        guard started,
              selection.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = selection.changeCount
        pendingPasteboardSelection = selection
        await offerPendingPasteboardSelectionIfPossible()
    }

    private func offerPendingPasteboardSelectionIfPossible() async {
        guard let selection = pendingPasteboardSelection,
              let destination = automaticDestination,
              connectedPeers.contains(destination),
              !selection.urls.isEmpty,
              !hasActiveTransfer(direction: .outgoing, peer: destination) else { return }
        pendingPasteboardSelection = nil
        do {
            _ = try await sendFiles(selection.urls, to: destination)
        } catch let error as FileTransferCoordinatorError {
            guard pendingPasteboardSelection == nil else { return }
            switch error {
            case .noDestination, .peerUnavailable, .peerBusy:
                pendingPasteboardSelection = selection
            default:
                break
            }
        } catch {
            // Invalid or inaccessible selections require a new Finder copy.
        }
    }

    private func handleTransportEvent(_ event: FileTransferTransportEvent) async {
        guard started else { return }
        switch event {
        case let .connected(deviceID):
            connectedPeers.insert(deviceID)
            await resumeTransfers(with: deviceID)
            await offerPendingPasteboardSelectionIfPossible()
        case let .disconnected(deviceID):
            connectedPeers.remove(deviceID)
            await pauseTransfers(with: deviceID)
        case let .message(deviceID, envelope):
            do {
                guard let workspace else { return }
                try envelope.validated(
                    workspaceID: workspace.id,
                    senderDeviceID: deviceID
                )
                try await handle(envelope.message, from: deviceID)
            } catch {
                let transferID = transferID(in: envelope.message)
                if let transferID { setFailure(failureCode(for: error), for: transferID) }
                try? await sendFailure(
                    transferID: transferID ?? TransferID(),
                    code: failureCode(for: error),
                    to: deviceID
                )
            }
        case let .failure(deviceID, code):
            if let deviceID { failActiveTransfers(with: deviceID, code: code) }
        }
    }

    private func handle(_ message: FileTransferMessage, from peer: DeviceID) async throws {
        switch message {
        case let .offer(offer):
            try await receiveOffer(offer, from: peer)
        case let .request(request):
            try receiveRequest(request, from: peer)
        case let .chunk(chunk):
            try await receiveChunk(chunk, from: peer)
        case let .acknowledgement(acknowledgement):
            try receiveAcknowledgement(acknowledgement, from: peer)
        case let .entryComplete(completion):
            try await receiveEntryCompletion(completion, from: peer)
        case let .transferComplete(completion):
            try await receiveTransferCompletion(completion, from: peer)
        case let .verification(verification):
            await receiveVerification(verification, from: peer)
        case let .cancellation(cancellation):
            await receiveCancellation(cancellation, from: peer)
        case let .resumeQuery(query):
            try await receiveResumeQuery(query, from: peer)
        case let .resumeState(state):
            try receiveResumeState(state, from: peer)
        case let .failure(failure):
            setFailure(failure.code, for: failure.transferID)
        }
    }

    private func receiveOffer(_ offer: TransferOffer, from peer: DeviceID) async throws {
        guard let localDevice, let workspace else { return }
        let manifest = try offer.manifest.validated(limits: limits)
        guard manifest.workspaceID == workspace.id else {
            throw FileTransferProtocolError.workspaceMismatch
        }
        guard manifest.sourceDeviceID == peer,
              manifest.destinationDeviceID == localDevice.id else {
            throw FileTransferProtocolError.peerMismatch
        }

        if let existing = records[manifest.transferID] {
            if existing.state == .completed {
                try await send(
                    .verification(TransferVerification(transferID: manifest.transferID, accepted: true)),
                    to: peer
                )
            } else {
                try await send(.resumeState(try await resumeState(for: existing)), to: peer)
            }
            return
        }
        guard !hasActiveTransfer(direction: .incoming, peer: peer) else {
            throw FileTransferCoordinatorError.transferRejected
        }

        try await store.prepareIncoming(manifest: manifest, limits: limits)
        let offsets = try await store.verifiedOffsets(for: manifest.transferID)
        records[manifest.transferID] = Record(
            manifest: manifest,
            direction: .incoming,
            peerDeviceID: peer,
            state: .preparing,
            verifiedOffsets: Dictionary(
                uniqueKeysWithValues: offsets.map { ($0.entryID, $0.offset) }
            ),
            failureCode: nil,
            completedAt: nil,
            stagedURLs: []
        )
        emit(manifest.transferID)
        setState(.transferring, for: manifest.transferID)
        try await send(
            .request(TransferRequest(transferID: manifest.transferID, offsets: offsets)),
            to: peer
        )
    }

    private func receiveRequest(_ request: TransferRequest, from peer: DeviceID) throws {
        guard let record = records[request.transferID],
              record.direction == .outgoing,
              record.peerDeviceID == peer else {
            throw FileTransferCoordinatorError.transferNotFound(request.transferID)
        }
        let offsets = try validatedOffsets(request.offsets, manifest: record.manifest)
        setState(.preparing, for: request.transferID, enforceTransition: false)
        setState(.transferring, for: request.transferID)
        startOutgoingTransfer(request.transferID, offsets: offsets)
    }

    private func receiveChunk(_ chunk: TransferChunk, from peer: DeviceID) async throws {
        guard var record = records[chunk.transferID],
              record.direction == .incoming,
              record.peerDeviceID == peer,
              record.state == .transferring else {
            throw FileTransferCoordinatorError.transferNotFound(chunk.transferID)
        }
        try chunk.validated(against: record.manifest, limits: limits)
        let expectedOffset = record.verifiedOffsets[chunk.entryID, default: 0]
        let chunkEnd = chunk.offset + UInt64(chunk.data.count)
        if chunk.offset < expectedOffset, chunkEnd <= expectedOffset {
            try await send(
                .acknowledgement(TransferAcknowledgement(
                    transferID: chunk.transferID,
                    entryID: chunk.entryID,
                    verifiedOffset: expectedOffset
                )),
                to: peer
            )
            return
        }
        guard chunk.offset == expectedOffset else {
            throw FileTransferProtocolError.invalidOffset(
                entryID: chunk.entryID,
                offset: chunk.offset
            )
        }
        let verifiedOffset = try await store.write(chunk, limits: limits)
        record.verifiedOffsets[chunk.entryID] = verifiedOffset
        records[chunk.transferID] = record
        emit(chunk.transferID)
        try await send(
            .acknowledgement(TransferAcknowledgement(
                transferID: chunk.transferID,
                entryID: chunk.entryID,
                verifiedOffset: verifiedOffset
            )),
            to: peer
        )
    }

    private func receiveAcknowledgement(
        _ acknowledgement: TransferAcknowledgement,
        from peer: DeviceID
    ) throws {
        guard var record = records[acknowledgement.transferID],
              record.direction == .outgoing,
              record.peerDeviceID == peer,
              let entry = record.manifest.entry(id: acknowledgement.entryID),
              acknowledgement.verifiedOffset <= entry.byteCount else {
            throw FileTransferProtocolError.invalidOffset(
                entryID: acknowledgement.entryID,
                offset: acknowledgement.verifiedOffset
            )
        }
        record.verifiedOffsets[acknowledgement.entryID] = max(
            record.verifiedOffsets[acknowledgement.entryID, default: 0],
            acknowledgement.verifiedOffset
        )
        records[acknowledgement.transferID] = record
        emit(acknowledgement.transferID)
    }

    private func receiveEntryCompletion(
        _ completion: TransferEntryCompletion,
        from peer: DeviceID
    ) async throws {
        guard let record = records[completion.transferID],
              record.direction == .incoming,
              record.peerDeviceID == peer,
              let entry = record.manifest.entry(id: completion.entryID) else {
            throw FileTransferCoordinatorError.transferNotFound(completion.transferID)
        }
        let url = try await store.finalizeEntry(
            transferID: completion.transferID,
            entryID: completion.entryID
        )
        if var updated = records[completion.transferID] {
            if !updated.stagedURLs.contains(url) { updated.stagedURLs.append(url) }
            updated.verifiedOffsets[completion.entryID] = entry.byteCount
            records[completion.transferID] = updated
            emit(completion.transferID)
        }
        try await send(
            .acknowledgement(TransferAcknowledgement(
                transferID: completion.transferID,
                entryID: completion.entryID,
                verifiedOffset: entry.byteCount
            )),
            to: peer
        )
    }

    private func receiveTransferCompletion(
        _ completion: TransferCompletion,
        from peer: DeviceID
    ) async throws {
        guard var record = records[completion.transferID],
              record.direction == .incoming,
              record.peerDeviceID == peer else {
            throw FileTransferCoordinatorError.transferNotFound(completion.transferID)
        }
        if record.state == .completed {
            try await send(
                .verification(TransferVerification(transferID: completion.transferID, accepted: true)),
                to: peer
            )
            return
        }

        // Finder publication can fail after every byte is verified. Allow the
        // sender to retry this terminal step without retransmitting file data.
        setState(.verifying, for: completion.transferID, enforceTransition: false)
        let urls = try await store.finalizeTransfer(completion.transferID)
        do {
            try await pasteboard.publishFilesChecked(urls, transferID: completion.transferID)
        } catch {
            let code: FileTransferFailureCode = switch error as? FilePasteboardPublicationError {
            case .invalidFileSet: .fileUnavailable
            case .writeRejected, .none: .stagingFailure
            }
            record = records[completion.transferID] ?? record
            record.state = .failed
            record.failureCode = code
            record.completedAt = Date()
            record.stagedURLs = urls
            record.verifiedOffsets = fullOffsets(for: record.manifest)
            records[completion.transferID] = record
            emit(completion.transferID)
            try await send(
                .verification(TransferVerification(
                    transferID: completion.transferID,
                    accepted: false,
                    failureCode: code
                )),
                to: peer
            )
            return
        }
        record = records[completion.transferID] ?? record
        record.state = .completed
        record.failureCode = nil
        record.completedAt = Date()
        record.stagedURLs = urls
        record.verifiedOffsets = fullOffsets(for: record.manifest)
        records[completion.transferID] = record
        emit(completion.transferID)
        try await send(
            .verification(TransferVerification(transferID: completion.transferID, accepted: true)),
            to: peer
        )
    }

    private func receiveVerification(_ verification: TransferVerification, from peer: DeviceID) async {
        guard var record = records[verification.transferID],
              record.direction == .outgoing,
              record.peerDeviceID == peer else { return }
        cancelTransferTask(verification.transferID)
        if verification.accepted {
            record.state = .completed
            record.failureCode = nil
            record.completedAt = Date()
            record.verifiedOffsets = fullOffsets(for: record.manifest)
            records[verification.transferID] = record
            await sourceProvider.removeOutgoingTransfer(verification.transferID)
        } else {
            record.state = .failed
            record.failureCode = verification.failureCode ?? .transferRejected
            record.completedAt = Date()
            records[verification.transferID] = record
        }
        emit(verification.transferID)
    }

    private func receiveCancellation(_ cancellation: TransferCancellation, from peer: DeviceID) async {
        guard var record = records[cancellation.transferID], record.peerDeviceID == peer else { return }
        cancelTransferTask(cancellation.transferID)
        if record.direction == .incoming {
            await store.cancel(cancellation.transferID)
        } else {
            await sourceProvider.removeOutgoingTransfer(cancellation.transferID)
        }
        record.state = .cancelled
        record.failureCode = cancellation.reason
        record.completedAt = Date()
        records[cancellation.transferID] = record
        emit(cancellation.transferID)
    }

    private func receiveResumeQuery(_ query: TransferResumeQuery, from peer: DeviceID) async throws {
        guard let record = records[query.transferID],
              record.direction == .incoming,
              record.peerDeviceID == peer else {
            throw FileTransferCoordinatorError.transferNotFound(query.transferID)
        }
        try await send(.resumeState(try await resumeState(for: record)), to: peer)
    }

    private func receiveResumeState(_ state: TransferResumeState, from peer: DeviceID) throws {
        guard var record = records[state.transferID],
              record.direction == .outgoing,
              record.peerDeviceID == peer else {
            throw FileTransferCoordinatorError.transferNotFound(state.transferID)
        }
        if state.completed {
            record.state = .completed
            record.failureCode = nil
            record.completedAt = Date()
            record.verifiedOffsets = fullOffsets(for: record.manifest)
            records[state.transferID] = record
            emit(state.transferID)
            let sourceProvider = self.sourceProvider
            Task { await sourceProvider.removeOutgoingTransfer(state.transferID) }
            return
        }
        let offsets = try validatedOffsets(state.offsets, manifest: record.manifest)
        record.verifiedOffsets = offsets
        records[state.transferID] = record
        setState(.transferring, for: state.transferID, enforceTransition: false)
        startOutgoingTransfer(state.transferID, offsets: offsets)
    }

    private func startOutgoingTransfer(
        _ transferID: TransferID,
        offsets: [TransferEntryID: UInt64]
    ) {
        cancelTransferTask(transferID)
        let token = UUID()
        transferTaskTokens[transferID] = token
        transferTasks[transferID] = Task { [weak self] in
            await self?.streamOutgoingTransfer(transferID, offsets: offsets, taskToken: token)
        }
    }

    private func streamOutgoingTransfer(
        _ transferID: TransferID,
        offsets initialOffsets: [TransferEntryID: UInt64],
        taskToken: UUID
    ) async {
        defer { finishTransferTask(transferID, token: taskToken) }
        guard let record = records[transferID], record.direction == .outgoing else { return }
        var offsets = initialOffsets
        do {
            for entry in record.manifest.entries {
                var offset = offsets[entry.id, default: 0]
                guard offset <= entry.byteCount else {
                    throw FileTransferProtocolError.invalidOffset(entryID: entry.id, offset: offset)
                }
                while offset < entry.byteCount {
                    try Task.checkCancellation()
                    let remaining = entry.byteCount - offset
                    let length = min(limits.defaultChunkSize, Int(clamping: remaining))
                    let data = try await sourceProvider.readChunk(
                        transferID: transferID,
                        entryID: entry.id,
                        offset: offset,
                        maximumLength: length
                    )
                    guard !data.isEmpty else { throw FileTransferCoordinatorError.sourceChanged }
                    let chunk = TransferChunk(
                        transferID: transferID,
                        entryID: entry.id,
                        offset: offset,
                        data: data
                    )
                    try chunk.validated(against: record.manifest, limits: limits)
                    try await send(.chunk(chunk), to: record.peerDeviceID)
                    offset += UInt64(data.count)
                    offsets[entry.id] = offset
                }
                try await send(
                    .entryComplete(TransferEntryCompletion(
                        transferID: transferID,
                        entryID: entry.id
                    )),
                    to: record.peerDeviceID
                )
            }
            setState(.verifying, for: transferID)
            try await send(
                .transferComplete(TransferCompletion(transferID: transferID)),
                to: record.peerDeviceID
            )
        } catch is CancellationError {
            return
        } catch {
            guard var current = records[transferID], !current.state.isTerminal else { return }
            let connected = connectedPeers.contains(current.peerDeviceID)
            current.state = connected ? .failed : .paused
            current.failureCode = connected ? failureCode(for: error) : .contentChannelUnavailable
            if current.state == .failed { current.completedAt = Date() }
            records[transferID] = current
            emit(transferID)
            if current.state == .failed {
                try? await sendFailure(
                    transferID: transferID,
                    code: current.failureCode ?? .unknown,
                    to: current.peerDeviceID
                )
            }
        }
    }

    private func resumeTransfers(with peer: DeviceID) async {
        let matching = records.values.filter { $0.peerDeviceID == peer && !$0.state.isTerminal }
        for record in matching {
            switch record.direction {
            case .outgoing:
                if record.state == .awaitingAcceptance || record.state == .offered {
                    try? await send(.offer(TransferOffer(manifest: record.manifest)), to: peer)
                } else {
                    try? await send(
                        .resumeQuery(TransferResumeQuery(transferID: record.manifest.transferID)),
                        to: peer
                    )
                }
            case .incoming:
                if let state = try? await resumeState(for: record) {
                    try? await send(.resumeState(state), to: peer)
                }
            }
        }
    }

    private func pauseTransfers(with peer: DeviceID) async {
        for record in records.values where record.peerDeviceID == peer && !record.state.isTerminal {
            cancelTransferTask(record.manifest.transferID)
            switch record.direction {
            case .incoming:
                await store.suspend(record.manifest.transferID)
            case .outgoing:
                await sourceProvider.suspend(record.manifest.transferID)
            }
            if record.state == .transferring || record.state == .verifying || record.state == .preparing {
                setState(.paused, for: record.manifest.transferID, enforceTransition: false)
            }
        }
    }

    private func failActiveTransfers(with peer: DeviceID, code: FileTransferFailureCode) {
        for record in records.values where record.peerDeviceID == peer && !record.state.isTerminal {
            setFailure(code, for: record.manifest.transferID)
        }
    }

    private func resumeState(for record: Record) async throws -> TransferResumeState {
        if record.state == .completed {
            return TransferResumeState(
                transferID: record.manifest.transferID,
                offsets: record.manifest.entries.map {
                    TransferEntryOffset(entryID: $0.id, offset: $0.byteCount)
                },
                completed: true
            )
        }
        let offsets = try await store.verifiedOffsets(for: record.manifest.transferID)
        return TransferResumeState(
            transferID: record.manifest.transferID,
            offsets: offsets,
            completed: false
        )
    }

    private func validatedOffsets(
        _ offsets: [TransferEntryOffset],
        manifest: TransferManifest
    ) throws -> [TransferEntryID: UInt64] {
        var result = zeroOffsets(for: manifest)
        var seen = Set<TransferEntryID>()
        for value in offsets {
            guard seen.insert(value.entryID).inserted,
                  let entry = manifest.entry(id: value.entryID),
                  value.offset <= entry.byteCount else {
                throw FileTransferProtocolError.invalidOffset(
                    entryID: value.entryID,
                    offset: value.offset
                )
            }
            result[value.entryID] = value.offset
        }
        return result
    }

    private func send(_ message: FileTransferMessage, to peer: DeviceID) async throws {
        guard let localDevice, let workspace else {
            throw FileTransferCoordinatorError.noDestination
        }
        try await transport.send(
            FileTransferEnvelope(
                workspaceID: workspace.id,
                senderDeviceID: localDevice.id,
                message: message
            ),
            to: peer
        )
    }

    private func sendFailure(
        transferID: TransferID,
        code: FileTransferFailureCode,
        to peer: DeviceID
    ) async throws {
        try await send(.failure(TransferFailure(transferID: transferID, code: code)), to: peer)
    }

    private func setState(
        _ state: FileTransferState,
        for transferID: TransferID,
        enforceTransition: Bool = true
    ) {
        guard var record = records[transferID] else { return }
        guard !enforceTransition || record.state.canTransition(to: state) else {
            record.state = .failed
            record.failureCode = .protocolViolation
            record.completedAt = Date()
            records[transferID] = record
            emit(transferID)
            return
        }
        record.state = state
        if state != .failed { record.failureCode = nil }
        if state.isTerminal { record.completedAt = record.completedAt ?? Date() }
        records[transferID] = record
        emit(transferID)
    }

    private func setFailure(_ code: FileTransferFailureCode, for transferID: TransferID) {
        guard var record = records[transferID], !record.state.isTerminal else { return }
        cancelTransferTask(transferID)
        record.state = .failed
        record.failureCode = code
        record.completedAt = Date()
        records[transferID] = record
        emit(transferID)
    }

    private func emit(_ transferID: TransferID) {
        guard let snapshot = records[transferID]?.snapshot else { return }
        yield(.snapshot(snapshot))
    }

    private func yield(_ event: FileTransferCoordinatorEvent) {
        guard case .dropped = continuation.yield(event) else { return }
        continuation.yield(.resync(snapshots()))
    }

    private func cancelTransferTask(_ transferID: TransferID) {
        transferTaskTokens.removeValue(forKey: transferID)
        transferTasks.removeValue(forKey: transferID)?.cancel()
    }

    private func finishTransferTask(_ transferID: TransferID, token: UUID) {
        guard transferTaskTokens[transferID] == token else { return }
        transferTaskTokens.removeValue(forKey: transferID)
        transferTasks.removeValue(forKey: transferID)
    }

    private func hasActiveTransfer(
        direction: FileTransferDirection,
        peer: DeviceID,
        excluding transferID: TransferID? = nil
    ) -> Bool {
        records.values.contains {
            $0.direction == direction &&
            $0.peerDeviceID == peer &&
            !$0.state.isTerminal &&
            $0.manifest.transferID != transferID
        }
    }

    private func zeroOffsets(for manifest: TransferManifest) -> [TransferEntryID: UInt64] {
        Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.id, UInt64(0)) })
    }

    private func fullOffsets(for manifest: TransferManifest) -> [TransferEntryID: UInt64] {
        Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.id, $0.byteCount) })
    }

    private func transferID(in message: FileTransferMessage) -> TransferID? {
        switch message {
        case let .offer(value): value.manifest.transferID
        case let .request(value): value.transferID
        case let .chunk(value): value.transferID
        case let .acknowledgement(value): value.transferID
        case let .entryComplete(value): value.transferID
        case let .transferComplete(value): value.transferID
        case let .verification(value): value.transferID
        case let .cancellation(value): value.transferID
        case let .resumeQuery(value): value.transferID
        case let .resumeState(value): value.transferID
        case let .failure(value): value.transferID
        }
    }

    private func failureCode(for error: Error) -> FileTransferFailureCode {
        if let error = error as? FileTransferCoordinatorError {
            switch error {
            case .sourceChanged: return .sourceChanged
            case .transferRejected, .peerBusy: return .transferRejected
            case .peerUnavailable, .noDestination: return .contentChannelUnavailable
            case .transferNotFound, .invalidState: return .protocolViolation
            }
        }
        if let error = error as? FileTransferProtocolError {
            switch error {
            case .invalidFilename, .duplicateEntry, .duplicateFilename,
                 .emptyManifest, .tooManyEntries:
                return .manifestInvalid
            case .transferTooLarge, .invalidFileSize, .invalidChunkSize:
                return .sizeLimitExceeded
            case .invalidOffset, .chunkExceedsEntry, .unknownEntry:
                return .invalidOffset
            case .invalidDigest:
                return .hashMismatch
            case .workspaceMismatch, .peerMismatch, .unsupportedVersion, .malformedEnvelope:
                return .protocolViolation
            }
        }
        if let error = error as? FilePasteboardPublicationError {
            switch error {
            case .invalidFileSet: return .fileUnavailable
            case .writeRejected: return .stagingFailure
            }
        }
        if let code = error as? FileTransferFailureCode { return code }
        return .unknown
    }
}
