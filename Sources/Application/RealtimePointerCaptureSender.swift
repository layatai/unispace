import Foundation
import UniSpaceDomain

final class RealtimePointerCaptureSender: @unchecked Sendable {
    private struct Session {
        let epoch: ControllerEpoch
        let target: DeviceID
        let sessionID: SessionID
        let generation: UInt64
        var sequence: UInt64
        var cumulativePointerX: Double
        var cumulativePointerY: Double
        var lastAcknowledgedSequence: UInt64?
        var lastAcknowledgementNanos: UInt64?
        var unacknowledgedSinceNanos: UInt64?
        var isSuspended = false
    }

    private let workspaceID: WorkspaceID
    private let localDeviceID: DeviceID
    private let transport: PeerTransport
    private let clock: MonotonicClock
    private let lock = NSLock()
    private var session: Session?
    private var progressTimeoutNanos = ControlSessionCoordinator.realtimeProgressTimeoutNanos

    init(
        workspaceID: WorkspaceID,
        localDeviceID: DeviceID,
        transport: PeerTransport,
        clock: MonotonicClock
    ) {
        self.workspaceID = workspaceID
        self.localDeviceID = localDeviceID
        self.transport = transport
        self.clock = clock
    }

    func enable(
        epoch: ControllerEpoch,
        target: DeviceID,
        sessionID: SessionID,
        generation: UInt64,
        sequence: UInt64,
        cumulativePointerX: Double,
        cumulativePointerY: Double,
        acknowledgedSequence: UInt64? = nil,
        acknowledgedAtNanos: UInt64? = nil
    ) {
        lock.withLock {
            session = Session(
                epoch: epoch,
                target: target,
                sessionID: sessionID,
                generation: generation,
                sequence: sequence,
                cumulativePointerX: cumulativePointerX,
                cumulativePointerY: cumulativePointerY,
                lastAcknowledgedSequence: acknowledgedSequence,
                lastAcknowledgementNanos: acknowledgedAtNanos,
                unacknowledgedSinceNanos: acknowledgedSequence.map { $0 &+ 1 == sequence } == true
                    ? nil : acknowledgedAtNanos
            )
        }
    }

    func takeCheckpoint(reliableSequence: UInt64) -> PointerCheckpoint? {
        lock.withLock {
            guard let active = session else { return nil }
            session = nil
            return .init(sessionID: active.sessionID, generation: active.generation,
                         reliableSequence: reliableSequence, cumulativeDeltaX: active.cumulativePointerX,
                         cumulativeDeltaY: active.cumulativePointerY)
        }
    }

    func disable() {
        lock.withLock { session = nil }
    }

    func suspend() {
        lock.withLock { session?.isSuspended = true }
    }

    func resume() {
        lock.withLock { session?.isSuspended = false }
    }

    func send(_ event: InputEvent) -> Bool {
        guard case let .pointerMove(deltaX, deltaY, absoluteX, absoluteY) = event else {
            return false
        }
        return lock.withLock {
            guard var active = session, !active.isSuspended else { return false }
            // Idle time is not packet loss. Start the deadline only when there
            // is movement outstanding, and never extend it just by sending.
            if let unacknowledgedSince = active.unacknowledgedSinceNanos {
                let now = clock.nowNanoseconds()
                guard now >= unacknowledgedSince,
                      now - unacknowledgedSince <= progressTimeoutNanos else {
                    return false
                }
            }
            if active.lastAcknowledgementNanos != nil, active.unacknowledgedSinceNanos == nil {
                active.unacknowledgedSinceNanos = clock.nowNanoseconds()
            }
            active.cumulativePointerX += deltaX
            active.cumulativePointerY += deltaY
            let frame = RealtimePointerFrame(
                workspaceID: workspaceID,
                sessionID: active.sessionID,
                controllerID: localDeviceID,
                epoch: active.epoch,
                generation: active.generation,
                sequence: active.sequence,
                deltaX: deltaX,
                deltaY: deltaY,
                cumulativeDeltaX: active.cumulativePointerX,
                cumulativeDeltaY: active.cumulativePointerY,
                absoluteX: absoluteX,
                absoluteY: absoluteY,
                timestampNanos: clock.nowNanoseconds()
            )
            active.sequence &+= 1
            guard transport.sendRealtimeImmediately(frame, to: active.target) else { return false }
            session = active
            return true
        }
    }

    func acknowledge(_ progress: RealtimePointerProgress, from source: DeviceID) -> Bool {
        lock.withLock {
            guard var active = session,
                  active.lastAcknowledgementNanos != nil,
                  active.target == source,
                  active.sessionID == progress.sessionID,
                  active.generation == progress.generation,
                  progress.sequence < active.sequence,
                  active.lastAcknowledgedSequence.map({ progress.sequence > $0 }) ?? true else {
                return false
            }
            active.lastAcknowledgedSequence = progress.sequence
            active.lastAcknowledgementNanos = clock.nowNanoseconds()
            active.unacknowledgedSinceNanos = progress.sequence &+ 1 == active.sequence
                ? nil : active.lastAcknowledgementNanos
            session = active
            return true
        }
    }

    func updateProgressTimeout(roundTripNanos: UInt64, jitterNanos: UInt64) {
        lock.withLock {
            let estimate = min(roundTripNanos, 1_000_000_000) + 4 * min(jitterNanos, 500_000_000) + 500_000_000
            progressTimeoutNanos = min(3_000_000_000, max(ControlSessionCoordinator.realtimeProgressTimeoutNanos, estimate))
        }
    }

    func hasExpiredOutstandingMotion() -> Bool {
        lock.withLock {
            guard let since = session?.unacknowledgedSinceNanos else { return false }
            let now = clock.nowNanoseconds()
            return now >= since && now - since > progressTimeoutNanos
        }
    }

    func hasFreshAcknowledgement() -> Bool {
        let now = clock.nowNanoseconds()
        return lock.withLock {
            guard let acknowledgedAt = session?.lastAcknowledgementNanos,
                  now >= acknowledgedAt else { return false }
            return now - acknowledgedAt <= progressTimeoutNanos
        }
    }

}
