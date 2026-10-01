import Foundation
import UniSpaceDomain

public final class RealtimeInputReceiver: @unchecked Sendable {
    private struct Session {
        let epoch: ControllerEpoch
        let source: DeviceID
        let sessionID: SessionID
        var generation: UInt64?
        var sequence: UInt64?
        var cumulativePointerX: Double = 0
        var cumulativePointerY: Double = 0
        var minimumGeneration: UInt64 = 0
        var pendingReliableSequence: UInt64?
    }

    private let workspaceID: WorkspaceID
    private let injector: InputInjector
    private let lock = NSLock()
    private var session: Session?

    public init(workspaceID: WorkspaceID, injector: InputInjector) {
        self.workspaceID = workspaceID
        self.injector = injector
    }

    public func begin(epoch: ControllerEpoch, source: DeviceID, sessionID: SessionID) {
        lock.withLock {
            session = Session(epoch: epoch, source: source, sessionID: sessionID)
        }
    }

    public func reset() {
        lock.withLock { session = nil }
    }

    @discardableResult
    public func receive(_ frame: RealtimePointerFrame, from source: DeviceID) -> RealtimePointerProgress? {
        lock.withLock {
            guard frame.workspaceID == workspaceID,
                  frame.controllerID == source,
                  var active = session,
                  active.epoch == frame.epoch,
                  active.source == source,
                  active.sessionID == frame.sessionID,
                  active.pendingReliableSequence == nil,
                  frame.generation >= active.minimumGeneration else { return nil }
            if let generation = active.generation, frame.generation < generation { return nil }
            if active.generation != frame.generation {
                active.generation = frame.generation
                active.sequence = nil
                active.cumulativePointerX = 0
                active.cumulativePointerY = 0
            }
            guard active.sequence.map({ frame.sequence > $0 }) ?? true else { return nil }
            let deltaX = frame.cumulativeDeltaX - active.cumulativePointerX
            let deltaY = frame.cumulativeDeltaY - active.cumulativePointerY
            guard deltaX.isFinite, deltaY.isFinite else { return nil }
            active.sequence = frame.sequence
            active.cumulativePointerX = frame.cumulativeDeltaX
            active.cumulativePointerY = frame.cumulativeDeltaY
            // Serialize injection with checkpoints, so a decoded old datagram
            // cannot be applied after a reliable button transition.
            injector.inject(.pointerMove(deltaX: deltaX, deltaY: deltaY,
                                         absoluteX: frame.absoluteX, absoluteY: frame.absoluteY))
            session = active
            return .init(sessionID: active.sessionID, generation: frame.generation, sequence: frame.sequence)
        }
    }

    @discardableResult
    public func applyCheckpoint(_ checkpoint: PointerCheckpoint, from source: DeviceID) -> Bool {
        lock.withLock {
            guard var active = session, active.source == source,
                  active.sessionID == checkpoint.sessionID,
                  checkpoint.generation >= active.minimumGeneration,
                  checkpoint.generation >= (active.generation ?? 0),
                  checkpoint.generation < UInt64.max,
                  checkpoint.cumulativeDeltaX.isFinite, checkpoint.cumulativeDeltaY.isFinite else { return false }
            let sameGeneration = active.generation == checkpoint.generation
            let deltaX = checkpoint.cumulativeDeltaX - (sameGeneration ? active.cumulativePointerX : 0)
            let deltaY = checkpoint.cumulativeDeltaY - (sameGeneration ? active.cumulativePointerY : 0)
            guard deltaX.isFinite, deltaY.isFinite else { return false }
            if deltaX != 0 || deltaY != 0 {
                injector.inject(.pointerMove(deltaX: deltaX, deltaY: deltaY, absoluteX: 0, absoluteY: 0))
            }
            active.minimumGeneration = checkpoint.generation + 1
            active.pendingReliableSequence = checkpoint.reliableSequence
            active.generation = nil
            active.sequence = nil
            active.cumulativePointerX = 0
            active.cumulativePointerY = 0
            session = active
            return true
        }
    }

    public func completeReliableInput(sequence: UInt64) {
        lock.withLock {
            if let pending = session?.pendingReliableSequence, sequence >= pending {
                session?.pendingReliableSequence = nil
            }
        }
    }

    public func progress(sessionID: SessionID, source: DeviceID) -> RealtimePointerProgress? {
        lock.withLock {
            guard let session,
                  session.source == source,
                  session.sessionID == sessionID,
                  let generation = session.generation,
                  let sequence = session.sequence else { return nil }
            return RealtimePointerProgress(
                sessionID: sessionID,
                generation: generation,
                sequence: sequence
            )
        }
    }
}
