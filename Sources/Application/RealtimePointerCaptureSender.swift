import Foundation
import UniSpaceDomain

final class RealtimePointerCaptureSender: @unchecked Sendable {
    private enum Mode: Equatable {
        case legacy
        case acknowledged
    }

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
        var isSuspended = false
        let mode: Mode
    }

    private let workspaceID: WorkspaceID
    private let localDeviceID: DeviceID
    private let transport: PeerTransport
    private let clock: MonotonicClock
    private let lock = NSLock()
    private var session: Session?

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

    func enableLegacy(
        epoch: ControllerEpoch,
        target: DeviceID,
        sessionID: SessionID,
        generation: UInt64,
        sequence: UInt64,
        cumulativePointerX: Double,
        cumulativePointerY: Double
    ) {
        enable(
            epoch: epoch,
            target: target,
            sessionID: sessionID,
            generation: generation,
            sequence: sequence,
            cumulativePointerX: cumulativePointerX,
            cumulativePointerY: cumulativePointerY,
            lastAcknowledgedSequence: nil,
            lastAcknowledgementNanos: nil,
            mode: .legacy
        )
    }

    func enableAcknowledged(
        epoch: ControllerEpoch,
        target: DeviceID,
        sessionID: SessionID,
        generation: UInt64,
        sequence: UInt64,
        cumulativePointerX: Double,
        cumulativePointerY: Double,
        acknowledgedSequence: UInt64,
        acknowledgedAtNanos: UInt64
    ) {
        enable(
            epoch: epoch,
            target: target,
            sessionID: sessionID,
            generation: generation,
            sequence: sequence,
            cumulativePointerX: cumulativePointerX,
            cumulativePointerY: cumulativePointerY,
            lastAcknowledgedSequence: acknowledgedSequence,
            lastAcknowledgementNanos: acknowledgedAtNanos,
            mode: .acknowledged
        )
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
        let prepared = lock.withLock { () -> (RealtimePointerFrame, DeviceID)? in
            guard var active = session, !active.isSuspended else { return nil }
            if active.mode == .acknowledged {
                let now = clock.nowNanoseconds()
                guard let acknowledgedAt = active.lastAcknowledgementNanos,
                      now >= acknowledgedAt,
                      now - acknowledgedAt <= ControlSessionCoordinator.realtimeProgressTimeoutNanos else {
                    return nil
                }
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
            session = active
            return (frame, active.target)
        }
        guard let prepared else { return false }
        return transport.sendRealtimeImmediately(prepared.0, to: prepared.1)
    }

    func acknowledge(_ progress: RealtimePointerProgress, from source: DeviceID) -> Bool {
        lock.withLock {
            guard var active = session,
                  active.mode == .acknowledged,
                  active.target == source,
                  active.sessionID == progress.sessionID,
                  active.generation == progress.generation,
                  progress.sequence < active.sequence,
                  active.lastAcknowledgedSequence.map({ progress.sequence > $0 }) ?? true else {
                return false
            }
            active.lastAcknowledgedSequence = progress.sequence
            active.lastAcknowledgementNanos = clock.nowNanoseconds()
            session = active
            return true
        }
    }

    private func enable(
        epoch: ControllerEpoch,
        target: DeviceID,
        sessionID: SessionID,
        generation: UInt64,
        sequence: UInt64,
        cumulativePointerX: Double,
        cumulativePointerY: Double,
        lastAcknowledgedSequence: UInt64?,
        lastAcknowledgementNanos: UInt64?,
        mode: Mode
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
                lastAcknowledgedSequence: lastAcknowledgedSequence,
                lastAcknowledgementNanos: lastAcknowledgementNanos,
                mode: mode
            )
        }
    }
}
