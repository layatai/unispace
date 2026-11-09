import Foundation
@testable import UniSpaceApplication
import UniSpaceDomain

// Deterministic loss/reorder simulation harness (issue #60), test-only.
// Documented limits, by design:
//   - No real time and no network: every drop/reorder/duplicate decision comes
//     from a local SplitMix64 stream seeded per direction, so identical seeds
//     replay the identical channel behavior for a scripted frame series.
//   - Reordering is bounded: at most `maxReorderSlots` frames are rebuffered at
//     once and released in adjacent-swapped (reversed) order once the buffer is
//     full, with a short flush timer draining the tail so delivery stays finite.
//   - Channel noise applies only to clipboard request/response frames carrying
//     a requestID; control frames (announce/withdraw/close) pass through so the
//     scripted scenarios need no retransmission logic of their own.
//   - A dropped frame synthesizes a `ClipboardStreamError` for its original
//     requestID back to the requester (link-failure emulation that bypasses the
//     noisy link), so unanswered requests fail typed instead of hanging until
//     the production 30 s request expiry.
// The paired clipboard scenario reuses the existing fakes of
// ClipboardStreamTests.swift (made internal here); no production source under
// Sources/ needed any change for this harness.

/// Pseudo-random split-mix generator over a single seeded state stream.
/// `next()` follows the standard SplitMix64 constants; no external dependency.
struct LossyRandom {
    private(set) var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform value in [0, 1) from the top 53 bits.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

struct LossyProfile: Sendable {
    let seed: UInt64
    let lossProbability: Double
    let reorderDelayProbability: Double
    let maxReorderSlots: Int
    let duplicateProbability: Double
    init(seed: UInt64, lossProbability: Double, reorderDelayProbability: Double,
         maxReorderSlots: Int = 4, duplicateProbability: Double) {
        self.seed = seed
        self.lossProbability = lossProbability
        assert(lossProbability >= 0 && lossProbability <= 1)
        self.reorderDelayProbability = reorderDelayProbability
        assert(reorderDelayProbability >= 0 && reorderDelayProbability <= 1)
        assert(maxReorderSlots >= 1)
        self.maxReorderSlots = maxReorderSlots
        self.duplicateProbability = duplicateProbability
        assert(duplicateProbability >= 0 && duplicateProbability <= 1)
    }
}

/// What happened to one fed frame on the noisy channel.
enum LossyDisposition: Equatable, Sendable {
    case deliver, deliverAndDuplicate, delay, delayAndDuplicate, drop
}

/// Deterministic channel that consumes one SplitMix64 stream while frames are
/// fed and hands out the permuted emission batch for each feed. Loss drops a
/// frame entirely; reorder rebuffering swaps adjacent pairs; copies arrive out
/// of order or immediately after the original. Pure and seed-deterministic.
final class LossyPipe<Element: Sendable>: @unchecked Sendable {
    private let profile: LossyProfile
    private var rng: LossyRandom
    private let lock = NSLock()
    private var pending: [Element] = []
    private var recordedDispositions: [LossyDisposition] = []

    init(profile: LossyProfile) {
        self.profile = profile
        rng = LossyRandom(seed: profile.seed)
    }

    struct FeedResult {
        let disposition: LossyDisposition
        var emissions: [Element] = []
    }

    func feed(_ element: Element) -> FeedResult {
        lock.lock(); defer { lock.unlock() }
        let lost = rng.unit() < profile.lossProbability
        let delayed = rng.unit() < profile.reorderDelayProbability
        let duplicated = rng.unit() < profile.duplicateProbability
        guard !lost else {
            recordedDispositions.append(.drop)
            return FeedResult(disposition: .drop)
        }
        if delayed || !pending.isEmpty {
            pending.append(element)
            if duplicated { pending.append(element) }
            let disposition: LossyDisposition = duplicated ? .delayAndDuplicate : .delay
            recordedDispositions.append(disposition)
            guard pending.count >= profile.maxReorderSlots else { return FeedResult(disposition: disposition) }
            let emissions = pending.reversed() as [Element]
            pending.removeAll()
            return FeedResult(disposition: disposition, emissions: emissions)
        }
        var emissions = [element]
        if duplicated { emissions.append(element) }
        let disposition: LossyDisposition = duplicated ? .deliverAndDuplicate : .deliver
        recordedDispositions.append(disposition)
        return FeedResult(disposition: disposition, emissions: emissions)
    }

    /// Emits rebuffered frames in adjacent-swapped (reversed) order; call once
    /// the scenario stops feeding so buffered tail frames still arrive.
    func flush() -> [Element] {
        lock.lock(); defer { lock.unlock() }
        let emissions = pending.reversed() as [Element]
        pending.removeAll()
        return emissions
    }

    var hasPending: Bool { lock.withLock { !pending.isEmpty } }
    var dispositions: [LossyDisposition] { lock.withLock { recordedDispositions } }
}

/// A clipboard frame worth perturbing, plus the metadata the lossy transport
/// needs to emulate link failures for it.
private struct LossyClipboardFrame: Sendable {
    let envelope: FileTransferEnvelope
    let destination: DeviceID
    let requestID: UUID
    let isRequest: Bool
}

private extension ClipboardStreamMessage {
    var streamRequestID: UUID? {
        switch self {
        case .open(let value): value.requestID
        case .read(let value): value.requestID
        case .finish(let value): value.requestID
        case .opened(let value): value.requestID
        case .range(let value): value.requestID
        case .finished(let value): value.requestID
        case .error(let value): value.requestID
        default: nil
        }
    }
    var isContentRequest: Bool {
        switch self {
        case .open, .read, .finish: true
        default: false
        }
    }
}

/// Lossy/reordering decorator around any `FileTransferTransport` fake. Both
/// directions of a paired simulation are wrapped separately, each with its own
/// seed, so channel behavior never depends on wall-clock or network timing.
final class LossyTransport<Base: FileTransferTransport>: FileTransferTransport, @unchecked Sendable {
    private let base: Base
    private let pipe: LossyPipe<LossyClipboardFrame>
    /// Route for synthesized failure notices about dropped requests, which must
    /// reach the requester in the opposite direction. When nil, dropped requests
    /// fall back to the production typed request expiry.
    let failureNoticeRoute: (@Sendable (FileTransferEnvelope) async -> Void)?
    private let lock = NSLock()
    private var flushing = false
    private static let flushDelayMilliseconds = 25

    init(base: Base, profile: LossyProfile,
         failureNoticeRoute: (@Sendable (FileTransferEnvelope) async -> Void)? = nil) {
        self.base = base
        pipe = LossyPipe(profile: profile)
        self.failureNoticeRoute = failureNoticeRoute
    }

    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {
        try await base.start(localDevice: localDevice, workspace: workspace, key: key)
    }
    func stop() async { await base.stop() }
    func events() -> AsyncStream<FileTransferTransportEvent> { base.events() }
    func setDesiredPeer(_ deviceID: DeviceID?) { base.setDesiredPeer(deviceID) }

    func send(_ envelope: FileTransferEnvelope, to deviceID: DeviceID) async throws {
        guard let frame = LossyClipboardFrame(envelope: envelope, to: deviceID) else {
            return try await base.send(envelope, to: deviceID) // control frames bypass the noisy channel
        }
        let result = pipe.feed(frame)
        for emission in result.emissions { try await forward(emission) }
        guard result.disposition == .drop else { scheduleTailFlushIfNeeded(); return }
        // Emulate a link failure for the dropped frame's requester so the denying
        // side fails typed with requestID echo instead of waiting for the expiry.
        let notice = FileTransferEnvelope(workspaceID: envelope.workspaceID,
            senderDeviceID: frame.isRequest ? frame.destination : envelope.senderDeviceID,
            message: .clipboardStream(.error(.init(requestID: frame.requestID, failure: .unavailable))))
        if frame.isRequest {
            guard let failureNoticeRoute else { scheduleTailFlushIfNeeded(); return } // the production request expiry answers the requester
            await failureNoticeRoute(notice)
        } else {
            try? await base.send(notice, to: deviceID)
        }
        scheduleTailFlushIfNeeded()
    }

    private func forward(_ frame: LossyClipboardFrame) async throws {
        try await base.send(frame.envelope, to: frame.destination)
    }

    private func scheduleTailFlushIfNeeded() {
        guard pipe.hasPending else { return }
        var startFlush = false
        lock.withLock {
            if !flushing { flushing = true; startFlush = true }
        }
        guard startFlush else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.flushDelayMilliseconds))
            guard let self else { return }
            while true {
                let batch = self.pipe.flush()
                guard !batch.isEmpty else { break }
                for frame in batch { try? await self.forward(frame) }
                await Task.yield()
            }
            self.lock.withLock { self.flushing = false }
            if self.pipe.hasPending { self.scheduleTailFlushIfNeeded() }
        }
    }
}

private extension LossyClipboardFrame {
    init?(envelope: FileTransferEnvelope, to destination: DeviceID) {
        guard case let .clipboardStream(message) = envelope.message,
              let requestID = message.streamRequestID else { return nil }
        self.envelope = envelope
        self.destination = destination
        self.requestID = requestID
        self.isRequest = message.isContentRequest
    }
}
