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

    public func receive(_ frame: RealtimePointerFrame, from source: DeviceID) {
        let event = lock.withLock { () -> InputEvent? in
            guard frame.workspaceID == workspaceID,
                  frame.controllerID == source,
                  var active = session,
                  active.epoch == frame.epoch,
                  active.source == source,
                  active.sessionID == frame.sessionID else { return nil }

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
            active.sequence = frame.sequence
            active.cumulativePointerX = frame.cumulativeDeltaX
            active.cumulativePointerY = frame.cumulativeDeltaY
            session = active
            return .pointerMove(
                deltaX: deltaX,
                deltaY: deltaY,
                absoluteX: frame.absoluteX,
                absoluteY: frame.absoluteY
            )
        }
        if let event { injector.inject(event) }
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
