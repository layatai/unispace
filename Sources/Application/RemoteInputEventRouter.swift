import Foundation
import UniSpaceDomain

public enum ControlTaskPriority {
    /// Remote input must not inherit UI, continuity, or bulk-transfer task QoS.
    public static let realtimeInput = TaskPriority(rawValue: 33)
}

public enum RemoteInputEventRouter {
    /// Routes latency-sensitive input without involving the application UI actor.
    @discardableResult
    public static func route(
        _ event: PeerEvent,
        to coordinator: ControlSessionCoordinator
    ) async -> Bool {
        switch event {
        case let .input(source, frame):
            await coordinator.handleIncoming(frame, from: source)
            return true
        case let .realtimeInput(source, frame):
            await coordinator.handleIncomingRealtime(frame, from: source)
            return true
        default:
            return false
        }
    }
}
