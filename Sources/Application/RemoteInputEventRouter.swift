import Foundation
import UniSpaceDomain

public enum ControlTaskPriority {
    /// Remote input must not inherit UI, continuity, or bulk-transfer task QoS.
    public static let realtimeInput = TaskPriority(rawValue: 33)
}

public enum RemoteInputEventRouter {
    /// Routes realtime input synchronously on the user-interactive consumer.
    @discardableResult
    public static func routeRealtime(
        _ event: PeerEvent,
        to coordinator: ControlSessionCoordinator
    ) -> Bool {
        guard case let .realtimeInput(source, frame) = event else { return false }
        coordinator.handleIncomingRealtime(frame, from: source)
        return true
    }

    /// Routes latency-sensitive input without involving the application UI actor.
    @discardableResult
    public static func route(
        _ event: PeerEvent,
        to coordinator: ControlSessionCoordinator
    ) async -> Bool {
        if routeRealtime(event, to: coordinator) { return true }
        switch event {
        case let .input(source, frame):
            await coordinator.handleIncoming(frame, from: source)
            return true
        default:
            return false
        }
    }
}
