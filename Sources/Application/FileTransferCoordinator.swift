import Foundation
import UniSpaceDomain

public actor FileTransferCoordinator {
    private struct Record: Sendable {
        let manifest: TransferManifest
        let direction: FileTransferDirection
        let peerDeviceID: DeviceID
        var state: FileTransferState
        var offsets: [TransferEntryID: UInt64]
        var failureCode: FileTransferFailureCode?
        var completedAt: Date?
        var stagedURLs: [URL]

        var transferredByteCount: UInt64 {
            manifest.entries.reduce(0) { partial, entry in
                let offset = min(offsets[entry.id, default: 0], entry.byteCount)
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
    private let clock: any MonotonicClock

    private let stream: AsyncStream<FileTransferCoordinatorEvent>
    private let continuation: AsyncStream<FileTransferCoordinatorEvent>.Continuation

    private var localDevice: DeviceDescriptor?
    private var workspace: WorkspaceSnapshot?
    private var records: [TransferID: Record] = [:]
    private var connectedPeers = Set<DeviceID>()
    private var automaticDestination: DeviceID?
    private var transferTasks: [TransferID: Task<Void, Never>] = [:]
    private var transportTask: Task<Void, Never>?
    private var pasteboardTask: Task<Void, Never>?
    private var lastPasteboardChangeCount: Int?
    private var started = false

    public init(
        transport: any FileTransferTransport,
        store: any TransferStore,
        sourceProvider: any FileSourceProvider,
        pasteboard: any FilePasteboard,
        limits: FileTransferLimits = .default,
        clock: any MonotonicClock = SystemMonotonicClock()
    ) {
        self.transport = transport
        self.store = store
        self.sourceProvider = sourceProvider
        self.pasteboard = pasteboard
        self.limits = limits
        self.clock = clock
        var captured: AsyncStream<FileTransferCoordinatorEvent>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    deinit {
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

        await store.removeExpired(now: Date(), limits: limits)
        try await recoverTransfers()
        try await transport.start(localDevice: localDevice, workspace: workspace, key: key)

        transportTask = Task { [weak self, transport] in
            for await event in transport.events() {
                guard !Task.isCancelled else { break }
                await self?.handleTransportEvent(event)
            }
        }

        let pasteboardEvents = await pasteboard.events()
        pasteboardTask = Task { [weak self] in
            for await selection in pasteboardEvents {
                guard !Task.isCancelled else { break }
                await self?.handlePasteboardSelection(selection)
            }
        }
    }

    public func stop() async {
        started = false
        transportTask?.cancel()
        pasteboardTask?.cancel()
        transportTask = nil
        pasteboardTask = nil
        transferTasks.values.forEach { $0.cancel() }
        transferTasks.removeAll()
        connectedPeers.removeAll()
        automaticDestination = nil
        await transport.stop()
    }

    public func setAutomaticDestination(_ deviceID: DeviceID?) {
        guard deviceID != localDevice?.id else {
            automaticDestination = nil
            return
        }
        automaticDestination = deviceID
    }

    public func connectedDeviceIDs() -> Set<DeviceID> { connectedPeers }

    @discardableResult
    public func sendFiles(_ urls: [URL], to destinationDeviceID: DeviceID? = nil) async throws -> TransferID {
        guard let localDevice, let workspace else {
            throw FileTransferCoordinatorError.noDestination
        }
        guard !urls.isEmpty else { throw FileTransferProtocolError.emptyManifest }
        guard let destination = destinationDeviceID ?? automaticDestination else {
            throw FileTransferCoordinatorError.noDestination
        }
        guard destination != localDevice.id else {
            throw FileTransferCoordinatorError.noDestination
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
        var offsets: [TransferEntryID: UInt64] = [:]
        manifest.entries.forEach { offsets[$0.id] = 0 }
        records[transferID] = Record(
            manifest: manifest,
            direction: .outgoing,
            peerDeviceID: destination,
            state: .offered,
            offsets: offsets,
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
        transferTasks.removeValue(forKey: transferID)?.cancel()
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
        transferTasks.removeValue(forKey: transferID)?.cancel()
        if record.direction == .incoming {
            await store.remove(transferID)
        } else {
            await sourceProvider.removeOutgoingTransfer(transferID)
        }
        records.removeValue(forKey: transferID)
        continuation.yield(.removed(transferID))
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
                offsets: Dictionary(uniqueKeysWithValues: recovered.offsets.map { ($0.entryID, $0.offset) }),
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
                offsets: Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.id, 0) }),
                failureCode: nil,
                completedAt: nil,
                stagedURLs: []
            )
            emit(manifest.transferID)
        }
    }

    private func handlePasteboardSelection(_ selection: PasteboardFileSelection) async {
        guard selection.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = selection.changeCount
        guard let destination = automaticDestination,
              connectedPeers.contains(destination),
              !selection.urls.isEmpty else { return }
        _ = try? await sendFiles(selection.urls, to: destination)
    }

    private func handleTransportEvent(_ event: FileTransferTransportEvent) async {
        switch event {
        case let .connected(deviceID):
            connectedPeers.insert(deviceID)
            await resumeTransfers(with: deviceID)
        case let .disconnected(deviceID):
            connectedPeers.remove(deviceID)
            pauseTransfers(with: deviceID)
        case let .message(deviceID, envelope):
            do {
                guard let workspace else { return }
                _ = try envelope.validated(
                    workspaceID: workspace.id,
                    senderDeviceID: deviceID
                )
                try await handle(envelope.message, from: deviceID)
            } catch {
                try? await sendFailure(
                    transferID: transferID(in: envelope.message) ?? TransferID(),
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

        try await store.prepareIncoming(manifest: manifest, limits: limits)
        let offsets = try await store.verifiedOffsets(for: manifest.transferID)
        records[manifest.transferID] = Record(
            manifest: manifest,
            direction: .incoming,
            peerDeviceID: peer,
            state: .preparing,
            offsets: Dictionary(uniqueKeysWithValues: offsets.map { ($0.entryID, $0.offset) }),
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
        _ = try chunk.validated(against: record.manifest, limits: limits)
        let expectedOffset = record.offsets[chunk.entryID, default: 0]
        guard chunk.offset == expectedOffset else {
            throw FileTransferProtocolError.invalidOffset(entryID: chunk.entryID, offset: chunk.offset)
        }
        let verifiedOffset = try await store.write(chunk, limits: limits)
        record.offsets[chunk.entryID] = verifiedOffset
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
        record.offsets[acknowledgement.entryID] = max(
            record.offsets[acknowledgement.entryID, default: 0],
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
              record.peerDeviceID == peer else {
            throw FileTransferCoordinatorError.transferNotFound(completion.transferID)
        }
        let url = try await store.finalizeEntry(
            transferID: completion.transferID,
            entryID: completion.entryID
        )
        if var updated = records[completion.transferID] {
            if !updated.stagedURLs.contains(url) { updated.stagedURLs.append(url) }
            if let entry = updated.manifest.entry(id: completion.entryID) {
                updated.offsets[completion.entryID] = entry.byteCount
            }
            records[completion.transferID] = updated
            emit(completion.transferID)
        }
        if let entry = record.manifest.entry(id: completion.entryID) {
            try await send(
                .acknowledgement(TransferAcknowledgement(
                    transferID: completion.transferID,
                    entryID: completion.entryID,
                    verifiedOffset: entry.byteCount
                )),
                to: peer
            )
        }
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

        setState(.verifying, for: completion.transferID)
        let urls = try await store.finalizeTransfer(completion.transferID)
        await pasteboard.publishFiles(urls, transferID: completion.transferID)
        record = records[completion.transferID] ?? record
        record.state = .completed
        record.failureCode = nil
        record.completedAt = Date()
        record.stagedURLs = urls
        record.offsets = Dictionary(uniqueKeysWithValues: record.manifest.entries.map { ($0.id, $0.byteCount) })
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
        transferTasks.removeValue(forKey: verification.transferID)?.cancel()
        if verification.accepted {
            record.state = .completed
            record.failureCode = nil
            record.completedAt = Date()
            record.offsets = Dictionary(uniqueKeysWithValues: record.manifest.entries.map { ($0.id, $0.byteCount) })
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
        transferTasks.removeValue(forKey: cancellation.transferID)?.cancel()
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
            record.offsets = Dictionary(uniqueKeysWithValues: record.manifest.entries.map { ($0.id, $0.byteCount) })
            records[state.transferID] = record
            emit(state.transferID)
            Task { [sourceProvider] in await sourceProvider.removeOutgoingTransfer(state.transferID) }
            return
        }
        let offsets = try validatedOffsets(state.offsets, manifest: record.manifest)
        setState(.transferring, for: state.transferID, enforceTransition: false)
        startOutgoingTransfer(state.transferID, offsets: offsets)
    }

    private func startOutgoingTransfer(
        _ transferID: TransferID,
        offsets: [TransferEntryID: UInt64]
    ) {
        transferTasks.removeValue(forKey: transferID)?.cancel()
        transferTasks[transferID] = Task { [weak self] in
            await self?.streamOutgoingTransfer(transferID, offsets: offsets)
        }
    }

    private func streamOutgoingTransfer(
        _ transferID: TransferID,
        offsets initialOffsets: [TransferEntryID: UInt64]
    ) async {
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
                    let chunk = try TransferChunk(
                        transferID: transferID,
                        entryID: entry.id,
                        offset: offset,
                        data: data
                    ).validated(against: record.manifest, limits: limits)
                    try await send(.chunk(chunk), to: record.peerDeviceID)
                    offset += UInt64(data.count)
                    offsets[entry.id] = offset
                    if var current = records[transferID] {
                        current.offsets[entry.id] = max(current.offsets[entry.id, default: 0], offset)
                        records[transferID] = current
                        emit(transferID)
                    }
                }
                try await send(
                    .entryComplete(TransferEntryCompletion(transferID: transferID, entryID: entry.id)),
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
            current.state = connectedPeers.contains(current.peerDeviceID) ? .failed : .paused
            current.failureCode = connectedPeers.contains(current.peerDeviceID)
                ? failureCode(for: error)
                : .contentChannelUnavailable
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

    private func pauseTransfers(with peer: DeviceID) {
        for record in records.values where record.peerDeviceID == peer && !record.state.isTerminal {
            transferTasks.removeValue(forKey: record.manifest.transferID)?.cancel()
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
        var result = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.id, UInt64(0)) })
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
        transferTasks.removeValue(forKey: transferID)?.cancel()
        record.state = .failed
        record.failureCode = code
        record.completedAt = Date()
        records[transferID] = record
        emit(transferID)
    }

    private func emit(_ transferID: TransferID) {
        guard let snapshot = records[transferID]?.snapshot else { return }
        continuation.yield(.snapshot(snapshot))
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
        switch error {
        case FileTransferCoordinatorError.sourceChanged:
            .sourceChanged
        case FileTransferCoordinatorError.transferRejected:
            .transferRejected
        case FileTransferProtocolError.invalidFilename,
             FileTransferProtocolError.duplicateEntry,
             FileTransferProtocolError.duplicateFilename,
             FileTransferProtocolError.emptyManifest,
             FileTransferProtocolError.tooManyEntries:
            .manifestInvalid
        case FileTransferProtocolError.transferTooLarge,
             FileTransferProtocolError.invalidFileSize,
             FileTransferProtocolError.invalidChunkSize:
            .sizeLimitExceeded
        case FileTransferProtocolError.invalidOffset,
             FileTransferProtocolError.chunkExceedsEntry,
             FileTransferProtocolError.unknownEntry:
            .invalidOffset
        case FileTransferProtocolError.invalidDigest:
            .hashMismatch
        case FileTransferProtocolError.workspaceMismatch,
             FileTransferProtocolError.peerMismatch,
             FileTransferProtocolError.unsupportedVersion,
             FileTransferProtocolError.malformedEnvelope:
            .protocolViolation
        default:
            .unknown
        }
    }
}
