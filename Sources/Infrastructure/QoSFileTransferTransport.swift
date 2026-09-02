import Foundation
import UniSpaceApplication
import UniSpaceDomain

public struct FileTransferControlQuality: Sendable, Equatable {
    public let isControlActive: Bool
    public let activePeerID: DeviceID?
    public let latencyMilliseconds: Int?

    public init(
        isControlActive: Bool,
        activePeerID: DeviceID? = nil,
        latencyMilliseconds: Int? = nil
    ) {
        self.isControlActive = isControlActive
        self.activePeerID = activePeerID
        self.latencyMilliseconds = latencyMilliseconds
    }

    public static let idle = Self(isControlActive: false)
}

public enum FileTransferQoSMode: String, Sendable, Equatable {
    case throughput
    case interactive
    case degraded
}

public struct FileTransferQoSPolicy: Sendable, Equatable {
    public let mode: FileTransferQoSMode
    public let chunkSize: Int
    public let maximumOutstandingBytes: UInt64
    public let targetBytesPerSecond: UInt64?

    public init(
        mode: FileTransferQoSMode,
        chunkSize: Int,
        maximumOutstandingBytes: UInt64,
        targetBytesPerSecond: UInt64?
    ) {
        self.mode = mode
        self.chunkSize = chunkSize
        self.maximumOutstandingBytes = maximumOutstandingBytes
        self.targetBytesPerSecond = targetBytesPerSecond
    }
}

public struct FileTransferQoSConfiguration: Sendable, Equatable {
    public static let `default` = Self()

    public let throughputChunkSize: Int
    public let interactiveChunkSize: Int
    public let degradedChunkSize: Int
    public let throughputOutstandingBytes: UInt64
    public let interactiveOutstandingBytes: UInt64
    public let degradedOutstandingBytes: UInt64
    public let interactiveBytesPerSecond: UInt64?
    public let degradedBytesPerSecond: UInt64?
    public let degradedLatencyMilliseconds: Int

    public init(
        throughputChunkSize: Int = 256 * 1_024,
        interactiveChunkSize: Int = 64 * 1_024,
        degradedChunkSize: Int = 64 * 1_024,
        throughputOutstandingBytes: UInt64 = 8 * 1_024 * 1_024,
        interactiveOutstandingBytes: UInt64 = 512 * 1_024,
        degradedOutstandingBytes: UInt64 = 256 * 1_024,
        interactiveBytesPerSecond: UInt64? = 8 * 1_024 * 1_024,
        degradedBytesPerSecond: UInt64? = 2 * 1_024 * 1_024,
        degradedLatencyMilliseconds: Int = 30
    ) {
        precondition(throughputChunkSize > 0)
        precondition(interactiveChunkSize > 0)
        precondition(degradedChunkSize > 0)
        precondition(throughputChunkSize <= FileTransferLimits.default.maximumChunkSize)
        precondition(interactiveChunkSize <= FileTransferLimits.default.maximumChunkSize)
        precondition(degradedChunkSize <= FileTransferLimits.default.maximumChunkSize)
        precondition(throughputOutstandingBytes >= UInt64(throughputChunkSize))
        precondition(interactiveOutstandingBytes >= UInt64(interactiveChunkSize))
        precondition(degradedOutstandingBytes >= UInt64(degradedChunkSize))
        precondition(interactiveBytesPerSecond.map { $0 > 0 } ?? true)
        precondition(degradedBytesPerSecond.map { $0 > 0 } ?? true)
        precondition(degradedLatencyMilliseconds > 0)
        self.throughputChunkSize = throughputChunkSize
        self.interactiveChunkSize = interactiveChunkSize
        self.degradedChunkSize = degradedChunkSize
        self.throughputOutstandingBytes = throughputOutstandingBytes
        self.interactiveOutstandingBytes = interactiveOutstandingBytes
        self.degradedOutstandingBytes = degradedOutstandingBytes
        self.interactiveBytesPerSecond = interactiveBytesPerSecond
        self.degradedBytesPerSecond = degradedBytesPerSecond
        self.degradedLatencyMilliseconds = degradedLatencyMilliseconds
    }

    public func policy(for peer: DeviceID, quality: FileTransferControlQuality) -> FileTransferQoSPolicy {
        guard quality.isControlActive else {
            return FileTransferQoSPolicy(
                mode: .throughput,
                chunkSize: throughputChunkSize,
                maximumOutstandingBytes: throughputOutstandingBytes,
                targetBytesPerSecond: nil
            )
        }
        let controlsSamePeer = quality.activePeerID == nil || quality.activePeerID == peer
        if controlsSamePeer,
           let latency = quality.latencyMilliseconds,
           latency >= degradedLatencyMilliseconds {
            return FileTransferQoSPolicy(
                mode: .degraded,
                chunkSize: degradedChunkSize,
                maximumOutstandingBytes: degradedOutstandingBytes,
                targetBytesPerSecond: degradedBytesPerSecond
            )
        }
        return FileTransferQoSPolicy(
            mode: .interactive,
            chunkSize: interactiveChunkSize,
            maximumOutstandingBytes: interactiveOutstandingBytes,
            targetBytesPerSecond: interactiveBytesPerSecond
        )
    }
}

public struct FileTransferQoSDiagnostics: Sendable, Equatable {
    public let policy: FileTransferQoSPolicy
    public let outstandingBytes: UInt64

    public init(policy: FileTransferQoSPolicy, outstandingBytes: UInt64) {
        self.policy = policy
        self.outstandingBytes = outstandingBytes
    }
}

/// Decorates the secure content transport with receiver-driven flow control and
/// controller-aware pacing. It deliberately leaves control, keyboard, and
/// pointer transports untouched.
public final class QoSFileTransferTransport: FileTransferTransport, @unchecked Sendable {
    private let underlying: any FileTransferTransport
    private let scheduler: FileTransferSendScheduler
    private let lock = NSLock()
    private let stream: AsyncStream<FileTransferTransportEvent>
    private let continuation: AsyncStream<FileTransferTransportEvent>.Continuation
    private var eventTask: Task<Void, Never>?

    public init(
        underlying: any FileTransferTransport,
        configuration: FileTransferQoSConfiguration = .default,
        clock: any MonotonicClock = SystemMonotonicClock()
    ) {
        self.underlying = underlying
        scheduler = FileTransferSendScheduler(configuration: configuration, clock: clock)
        var captured: AsyncStream<FileTransferTransportEvent>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    deinit {
        lock.qosWithLock { eventTask?.cancel() }
        continuation.finish()
    }

    public func events() -> AsyncStream<FileTransferTransportEvent> { stream }

    public func start(
        localDevice: DeviceDescriptor,
        workspace: WorkspaceSnapshot,
        key: Data
    ) async throws {
        startEventForwardingIfNeeded()
        await scheduler.reset()
        try await underlying.start(localDevice: localDevice, workspace: workspace, key: key)
    }

    public func stop() async {
        await scheduler.reset()
        await underlying.stop()
    }

    public func setDesiredPeer(_ deviceID: DeviceID?) {
        underlying.setDesiredPeer(deviceID)
    }

    public func updateControlQuality(_ quality: FileTransferControlQuality) async {
        await scheduler.updateControlQuality(quality)
    }

    public func diagnostics(
        peer: DeviceID,
        transferID: TransferID? = nil,
        entryID: TransferEntryID? = nil
    ) async -> FileTransferQoSDiagnostics {
        await scheduler.diagnostics(peer: peer, transferID: transferID, entryID: entryID)
    }

    public func send(_ envelope: FileTransferEnvelope, to deviceID: DeviceID) async throws {
        switch envelope.message {
        case let .chunk(chunk):
            try await sendChunk(chunk, envelope: envelope, to: deviceID)
        case let .entryComplete(completion):
            try await scheduler.waitUntilAcknowledged(
                peer: deviceID,
                transferID: completion.transferID,
                entryID: completion.entryID
            )
            try await underlying.send(envelope, to: deviceID)
        case let .cancellation(cancellation):
            do {
                try await underlying.send(envelope, to: deviceID)
            } catch {
                await scheduler.cancel(transferID: cancellation.transferID, peer: deviceID)
                throw error
            }
            await scheduler.cancel(transferID: cancellation.transferID, peer: deviceID)
        case let .failure(failure):
            do {
                try await underlying.send(envelope, to: deviceID)
            } catch {
                await scheduler.cancel(transferID: failure.transferID, peer: deviceID)
                throw error
            }
            await scheduler.cancel(transferID: failure.transferID, peer: deviceID)
        case let .verification(verification):
            try await underlying.send(envelope, to: deviceID)
            await scheduler.finish(transferID: verification.transferID, peer: deviceID)
        default:
            try await underlying.send(envelope, to: deviceID)
        }
    }

    private func sendChunk(
        _ chunk: TransferChunk,
        envelope: FileTransferEnvelope,
        to peer: DeviceID
    ) async throws {
        var cursor = 0
        var offset = chunk.offset
        while cursor < chunk.data.count {
            try Task.checkCancellation()
            let policy = await scheduler.currentPolicy(for: peer)
            let length = min(policy.chunkSize, chunk.data.count - cursor)
            let end = cursor + length
            let fragment = TransferChunk(
                transferID: chunk.transferID,
                entryID: chunk.entryID,
                offset: offset,
                data: chunk.data.subdata(in: cursor..<end)
            )
            try await scheduler.reserveAndPace(
                peer: peer,
                transferID: chunk.transferID,
                entryID: chunk.entryID,
                offset: offset,
                byteCount: length
            )
            let fragmentEnvelope = FileTransferEnvelope(
                version: envelope.version,
                workspaceID: envelope.workspaceID,
                senderDeviceID: envelope.senderDeviceID,
                message: .chunk(fragment)
            )
            do {
                try await underlying.send(fragmentEnvelope, to: peer)
            } catch {
                await scheduler.rollBackReservation(
                    peer: peer,
                    transferID: chunk.transferID,
                    entryID: chunk.entryID,
                    offset: offset,
                    byteCount: length
                )
                throw error
            }
            cursor = end
            offset += UInt64(length)
        }
    }

    private func startEventForwardingIfNeeded() {
        let shouldStart = lock.qosWithLock { eventTask == nil }
        guard shouldStart else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            for await event in underlying.events() {
                guard !Task.isCancelled else { return }
                await scheduler.observe(event)
                continuation.yield(event)
            }
        }
        lock.qosWithLock {
            if eventTask == nil {
                eventTask = task
            } else {
                task.cancel()
            }
        }
    }
}

private actor FileTransferSendScheduler {
    private struct TransferKey: Hashable {
        let peer: DeviceID
        let transferID: TransferID
    }

    private struct FlowKey: Hashable {
        let peer: DeviceID
        let transferID: TransferID
        let entryID: TransferEntryID
    }

    private struct FlowState {
        var sentOffset: UInt64
        var acknowledgedOffset: UInt64
    }

    private struct Bucket {
        var tokens: Double
        var lastRefillNanoseconds: UInt64
        var rate: UInt64
        var capacity: Double
    }

    private struct Waiter {
        let key: FlowKey
        let generation: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private let configuration: FileTransferQoSConfiguration
    private let clock: any MonotonicClock
    private var quality = FileTransferControlQuality.idle
    private var flows: [FlowKey: FlowState] = [:]
    private var buckets: [DeviceID: Bucket] = [:]
    private var cancelledTransfers = Set<TransferKey>()
    private var disconnectedPeers = Set<DeviceID>()
    private var waiters: [UUID: Waiter] = [:]
    private var generation: UInt64 = 0

    init(configuration: FileTransferQoSConfiguration, clock: any MonotonicClock) {
        self.configuration = configuration
        self.clock = clock
    }

    func reset() {
        generation &+= 1
        quality = .idle
        flows.removeAll(keepingCapacity: true)
        buckets.removeAll(keepingCapacity: true)
        cancelledTransfers.removeAll(keepingCapacity: true)
        disconnectedPeers.removeAll(keepingCapacity: true)
        resumeAllWaiters()
    }

    func updateControlQuality(_ value: FileTransferControlQuality) {
        guard quality != value else { return }
        quality = value
        buckets.removeAll(keepingCapacity: true)
        resumeAllWaiters()
    }

    func currentPolicy(for peer: DeviceID) -> FileTransferQoSPolicy {
        configuration.policy(for: peer, quality: quality)
    }

    func diagnostics(
        peer: DeviceID,
        transferID: TransferID?,
        entryID: TransferEntryID?
    ) -> FileTransferQoSDiagnostics {
        let outstanding: UInt64
        if let transferID, let entryID,
           let state = flows[FlowKey(peer: peer, transferID: transferID, entryID: entryID)] {
            outstanding = state.sentOffset >= state.acknowledgedOffset
                ? state.sentOffset - state.acknowledgedOffset
                : 0
        } else {
            outstanding = flows.reduce(UInt64(0)) { partial, element in
                guard element.key.peer == peer else { return partial }
                let value = element.value.sentOffset >= element.value.acknowledgedOffset
                    ? element.value.sentOffset - element.value.acknowledgedOffset
                    : 0
                let (sum, overflow) = partial.addingReportingOverflow(value)
                return overflow ? UInt64.max : sum
            }
        }
        return FileTransferQoSDiagnostics(
            policy: currentPolicy(for: peer),
            outstandingBytes: outstanding
        )
    }

    func reserveAndPace(
        peer: DeviceID,
        transferID: TransferID,
        entryID: TransferEntryID,
        offset: UInt64,
        byteCount: Int
    ) async throws {
        guard byteCount > 0 else { return }
        try await acquireRatePermit(peer: peer, byteCount: byteCount)
        let key = FlowKey(peer: peer, transferID: transferID, entryID: entryID)
        let transferKey = TransferKey(peer: peer, transferID: transferID)
        let expectedGeneration = generation
        let (endOffset, overflow) = offset.addingReportingOverflow(UInt64(byteCount))
        guard !overflow else { throw FileTransferProtocolError.invalidOffset(entryID: entryID, offset: offset) }

        while true {
            try Task.checkCancellation()
            guard expectedGeneration == generation,
                  !disconnectedPeers.contains(peer),
                  !cancelledTransfers.contains(transferKey) else {
                throw CancellationError()
            }
            var state = flows[key] ?? FlowState(sentOffset: offset, acknowledgedOffset: offset)
            if state.sentOffset != offset {
                state.sentOffset = offset
                state.acknowledgedOffset = min(state.acknowledgedOffset, offset)
            }
            let acknowledged = min(state.acknowledgedOffset, endOffset)
            let outstanding = endOffset - acknowledged
            let policy = currentPolicy(for: peer)
            if outstanding <= policy.maximumOutstandingBytes {
                state.sentOffset = endOffset
                flows[key] = state
                return
            }
            try await waitForCredit(key: key, generation: expectedGeneration)
        }
    }

    func rollBackReservation(
        peer: DeviceID,
        transferID: TransferID,
        entryID: TransferEntryID,
        offset: UInt64,
        byteCount: Int
    ) {
        let key = FlowKey(peer: peer, transferID: transferID, entryID: entryID)
        guard var state = flows[key] else { return }
        let end = offset + UInt64(byteCount)
        if state.sentOffset == end {
            state.sentOffset = max(offset, state.acknowledgedOffset)
            flows[key] = state
            resumeWaiters(for: key)
        }
    }

    func waitUntilAcknowledged(
        peer: DeviceID,
        transferID: TransferID,
        entryID: TransferEntryID
    ) async throws {
        let key = FlowKey(peer: peer, transferID: transferID, entryID: entryID)
        let transferKey = TransferKey(peer: peer, transferID: transferID)
        let expectedGeneration = generation
        while let state = flows[key], state.acknowledgedOffset < state.sentOffset {
            try Task.checkCancellation()
            guard expectedGeneration == generation,
                  !disconnectedPeers.contains(peer),
                  !cancelledTransfers.contains(transferKey) else {
                throw CancellationError()
            }
            try await waitForCredit(key: key, generation: expectedGeneration)
        }
    }

    func observe(_ event: FileTransferTransportEvent) {
        switch event {
        case let .connected(peer):
            disconnectedPeers.remove(peer)
            resumeWaiters(for: peer)
        case let .disconnected(peer):
            disconnectedPeers.insert(peer)
            buckets.removeValue(forKey: peer)
            resumeWaiters(for: peer)
        case let .failure(peer, _):
            if let peer {
                disconnectedPeers.insert(peer)
                buckets.removeValue(forKey: peer)
                resumeWaiters(for: peer)
            }
        case let .message(peer, envelope):
            observe(message: envelope.message, from: peer)
        }
    }

    func cancel(transferID: TransferID, peer: DeviceID) {
        let key = TransferKey(peer: peer, transferID: transferID)
        cancelledTransfers.insert(key)
        removeFlows(for: key)
    }

    func finish(transferID: TransferID, peer: DeviceID) {
        let key = TransferKey(peer: peer, transferID: transferID)
        cancelledTransfers.remove(key)
        removeFlows(for: key)
    }

    private func observe(message: FileTransferMessage, from peer: DeviceID) {
        switch message {
        case let .request(request):
            prepare(peer: peer, transferID: request.transferID, offsets: request.offsets)
        case let .resumeState(state):
            if state.completed {
                finish(transferID: state.transferID, peer: peer)
            } else {
                prepare(peer: peer, transferID: state.transferID, offsets: state.offsets)
            }
        case let .acknowledgement(acknowledgement):
            acknowledge(
                peer: peer,
                transferID: acknowledgement.transferID,
                entryID: acknowledgement.entryID,
                offset: acknowledgement.verifiedOffset
            )
        case let .verification(verification):
            finish(transferID: verification.transferID, peer: peer)
        case let .cancellation(cancellation):
            cancel(transferID: cancellation.transferID, peer: peer)
        case let .failure(failure):
            cancel(transferID: failure.transferID, peer: peer)
        default:
            break
        }
    }

    private func prepare(
        peer: DeviceID,
        transferID: TransferID,
        offsets: [TransferEntryOffset]
    ) {
        let transferKey = TransferKey(peer: peer, transferID: transferID)
        cancelledTransfers.remove(transferKey)
        removeFlows(for: transferKey)
        for offset in offsets {
            let key = FlowKey(peer: peer, transferID: transferID, entryID: offset.entryID)
            flows[key] = FlowState(sentOffset: offset.offset, acknowledgedOffset: offset.offset)
        }
    }

    private func acknowledge(
        peer: DeviceID,
        transferID: TransferID,
        entryID: TransferEntryID,
        offset: UInt64
    ) {
        let key = FlowKey(peer: peer, transferID: transferID, entryID: entryID)
        guard var state = flows[key] else {
            flows[key] = FlowState(sentOffset: offset, acknowledgedOffset: offset)
            return
        }
        state.acknowledgedOffset = min(max(state.acknowledgedOffset, offset), state.sentOffset)
        flows[key] = state
        resumeWaiters(for: key)
    }

    private func acquireRatePermit(peer: DeviceID, byteCount: Int) async throws {
        while true {
            try Task.checkCancellation()
            let policy = currentPolicy(for: peer)
            guard let rate = policy.targetBytesPerSecond else {
                buckets.removeValue(forKey: peer)
                return
            }
            let now = clock.nowNanoseconds()
            let capacity = max(
                Double(policy.chunkSize * 2),
                min(Double(policy.maximumOutstandingBytes), Double(rate) / 8)
            )
            var bucket = buckets[peer] ?? Bucket(
                tokens: capacity,
                lastRefillNanoseconds: now,
                rate: rate,
                capacity: capacity
            )
            if bucket.rate != rate || bucket.capacity != capacity {
                bucket.rate = rate
                bucket.capacity = capacity
                bucket.tokens = min(bucket.tokens, capacity)
            }
            if now > bucket.lastRefillNanoseconds {
                let elapsed = Double(now - bucket.lastRefillNanoseconds) / 1_000_000_000
                bucket.tokens = min(capacity, bucket.tokens + elapsed * Double(rate))
                bucket.lastRefillNanoseconds = now
            }
            let required = Double(byteCount)
            if bucket.tokens >= required {
                bucket.tokens -= required
                buckets[peer] = bucket
                return
            }
            let deficit = required - bucket.tokens
            buckets[peer] = bucket
            let rawWait = UInt64((deficit / Double(rate)) * 1_000_000_000)
            let waitNanoseconds = min(max(rawWait, 1_000_000), 250_000_000)
            try await clock.sleep(for: .nanoseconds(Int64(waitNanoseconds)))
        }
    }

    private func waitForCredit(key: FlowKey, generation expectedGeneration: UInt64) async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard expectedGeneration == generation else {
                    continuation.resume()
                    return
                }
                waiters[id] = Waiter(
                    key: key,
                    generation: expectedGeneration,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        try Task.checkCancellation()
        guard expectedGeneration == generation else { throw CancellationError() }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }

    private func removeFlows(for transfer: TransferKey) {
        let keys = flows.keys.filter {
            $0.peer == transfer.peer && $0.transferID == transfer.transferID
        }
        for key in keys {
            flows.removeValue(forKey: key)
            resumeWaiters(for: key)
        }
    }

    private func resumeWaiters(for key: FlowKey) {
        let ids = waiters.compactMap { id, waiter in waiter.key == key ? id : nil }
        for id in ids { waiters.removeValue(forKey: id)?.continuation.resume() }
    }

    private func resumeWaiters(for peer: DeviceID) {
        let ids = waiters.compactMap { id, waiter in waiter.key.peer == peer ? id : nil }
        for id in ids { waiters.removeValue(forKey: id)?.continuation.resume() }
    }

    private func resumeAllWaiters() {
        let values = waiters.values.map(\.continuation)
        waiters.removeAll(keepingCapacity: true)
        values.forEach { $0.resume() }
    }
}

private extension NSLock {
    func qosWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
