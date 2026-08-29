import Foundation
import UniSpaceDomain

public struct EdgeTransition: Equatable, Sendable {
    public let sourceDisplayID: DisplayID
    public let sourceEdge: DisplayEdge
    public let targetDisplayID: DisplayID
    public let targetDeviceID: DeviceID
    public let entryEdge: DisplayEdge
    public let normalizedPosition: Double

    public init(
        sourceDisplayID: DisplayID,
        sourceEdge: DisplayEdge,
        targetDisplayID: DisplayID,
        targetDeviceID: DeviceID,
        entryEdge: DisplayEdge,
        normalizedPosition: Double
    ) {
        self.sourceDisplayID = sourceDisplayID
        self.sourceEdge = sourceEdge
        self.targetDisplayID = targetDisplayID
        self.targetDeviceID = targetDeviceID
        self.entryEdge = entryEdge
        self.normalizedPosition = normalizedPosition
    }
}

public struct EntryEdgeHysteresis: Equatable, Sendable {
    public static let defaultInwardDistance = 12.0

    private struct GuardedEdge: Equatable, Sendable {
        let displayID: DisplayID
        let edge: DisplayEdge
        let frame: DisplayRect
    }

    private let minimumInwardDistance: Double
    private var guardedEdge: GuardedEdge?

    public init(minimumInwardDistance: Double = Self.defaultInwardDistance) {
        self.minimumInwardDistance = max(minimumInwardDistance, 0)
    }

    public mutating func arm(display: DisplayDescriptor, entryEdge: DisplayEdge) {
        guardedEdge = GuardedEdge(displayID: display.id, edge: entryEdge, frame: display.frame)
    }

    public mutating func reset() {
        guardedEdge = nil
    }

    public mutating func observe(x: Double, y: Double) {
        guard let guardedEdge else { return }
        let inwardDistance: Double
        switch guardedEdge.edge {
        case .left:
            inwardDistance = x - guardedEdge.frame.minX
        case .right:
            inwardDistance = guardedEdge.frame.maxX - x
        case .bottom:
            inwardDistance = y - guardedEdge.frame.minY
        case .top:
            inwardDistance = guardedEdge.frame.maxY - y
        }
        if inwardDistance >= minimumInwardDistance {
            self.guardedEdge = nil
        }
    }

    public func allows(_ transition: EdgeTransition) -> Bool {
        guard let guardedEdge else { return true }
        return transition.sourceDisplayID != guardedEdge.displayID
            || transition.sourceEdge != guardedEdge.edge
    }
}

/// Serializes local edge transfers and prevents a manual stop from being
/// undone by an activation task that was already in flight.
public struct ControlTransferGuard: Equatable, Sendable {
    public struct ActivationAttempt: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    private struct ExitEdge: Equatable, Sendable {
        let display: DisplayDescriptor
        let edge: DisplayEdge
    }

    private enum Phase: Equatable, Sendable {
        case idle
        case activating(ActivationAttempt, ExitEdge)
        case controlling(ExitEdge)
        case stopping(ExitEdge?)
    }

    private var phase: Phase = .idle
    private var nextAttemptID: UInt64 = 0
    private var hysteresis: EntryEdgeHysteresis

    public init(minimumInwardDistance: Double = EntryEdgeHysteresis.defaultInwardDistance) {
        hysteresis = EntryEdgeHysteresis(minimumInwardDistance: minimumInwardDistance)
    }

    public mutating func observe(x: Double, y: Double) {
        hysteresis.observe(x: x, y: y)
    }

    public var forwardsCapturedInput: Bool {
        if case .controlling = phase { return true }
        return false
    }

    public func allows(_ transition: EdgeTransition) -> Bool {
        guard phase == .idle else { return false }
        return hysteresis.allows(transition)
    }

    public mutating func beginActivation(
        _ transition: EdgeTransition,
        sourceDisplay: DisplayDescriptor
    ) -> ActivationAttempt? {
        guard allows(transition) else { return nil }
        let attempt = ActivationAttempt(id: nextAttemptID)
        nextAttemptID &+= 1
        let exit = ExitEdge(display: sourceDisplay, edge: transition.sourceEdge)
        hysteresis.arm(display: sourceDisplay, entryEdge: transition.sourceEdge)
        phase = .activating(attempt, exit)
        return attempt
    }

    /// Returns false when a stop superseded this activation attempt.
    public mutating func activationSucceeded(_ attempt: ActivationAttempt) -> Bool {
        guard case let .activating(activeAttempt, exit) = phase,
              activeAttempt == attempt else { return false }
        phase = .controlling(exit)
        return true
    }

    public mutating func activationFailed(_ attempt: ActivationAttempt) {
        guard case let .activating(activeAttempt, _) = phase,
              activeAttempt == attempt else { return }
        phase = .idle
    }

    public mutating func beginStop() {
        switch phase {
        case .idle:
            phase = .stopping(nil)
        case let .activating(_, exit), let .controlling(exit):
            phase = .stopping(exit)
        case .stopping:
            break
        }
    }

    public mutating func completeStop() {
        guard case let .stopping(exit) = phase else { return }
        if let exit {
            hysteresis.arm(display: exit.display, entryEdge: exit.edge)
        }
        phase = .idle
    }

    public mutating func returned(to display: DisplayDescriptor, enteringFrom edge: DisplayEdge) {
        hysteresis.arm(display: display, entryEdge: edge)
        phase = .idle
    }

    public mutating func reset() {
        phase = .idle
        hysteresis.reset()
    }
}

public enum EdgeRouter {
    public static func transition(
        x: Double,
        y: Double,
        localDeviceID: DeviceID,
        devices: [DeviceDescriptor],
        topology: DisplayTopology,
        tolerance: Double = 1.5,
        availableDeviceIDs: Set<DeviceID>? = nil
    ) -> EdgeTransition? {
        let displays = devices.flatMap(\.displays)
        let displaysByID = index(displays)
        let localDisplays = displays.filter { $0.deviceID == localDeviceID }
        if let source = localDisplays.first(where: {
            x >= $0.frame.minX - tolerance && x <= $0.frame.maxX + tolerance
                && y >= $0.frame.minY - tolerance && y <= $0.frame.maxY + tolerance
        }) {
            let edge: DisplayEdge?
            if x <= source.frame.minX + tolerance { edge = .left }
            else if x >= source.frame.maxX - tolerance { edge = .right }
            else if y <= source.frame.minY + tolerance { edge = .bottom }
            else if y >= source.frame.maxY - tolerance { edge = .top }
            else { edge = nil }
            guard let edge else { return nil }
            return makeTransition(
                source: source,
                edge: edge,
                x: x,
                y: y,
                localDeviceID: localDeviceID,
                displays: displays,
                displaysByID: displaysByID,
                topology: topology,
                availableDeviceIDs: availableDeviceIDs
            )
        }

        let overshotEdges = localDisplays.flatMap { source in
            DisplayEdge.allCases.compactMap { edge -> (DisplayDescriptor, DisplayEdge, Double)? in
                guard topology.destination(from: source.id, edge: edge) != nil else { return nil }
                if let availableDeviceIDs {
                    guard resolveReachableDestination(
                        from: source.id,
                        edge: edge,
                        displaysByID: displaysByID,
                        topology: topology,
                        availableDeviceIDs: availableDeviceIDs
                    ) != nil else { return nil }
                }
                guard isBeyond(edge, of: source.frame, x: x, y: y, tolerance: tolerance) else { return nil }
                return (source, edge, distance(to: edge, of: source.frame, x: x, y: y))
            }
        }
        guard let (source, edge, _) = overshotEdges.min(by: { $0.2 < $1.2 }) else { return nil }
        return makeTransition(
            source: source,
            edge: edge,
            x: x,
            y: y,
            localDeviceID: localDeviceID,
            displays: displays,
            displaysByID: displaysByID,
            topology: topology,
            availableDeviceIDs: availableDeviceIDs
        )
    }

    /// Follows a display chain through unavailable devices and returns the first
    /// reachable destination. Entering an unavailable display through one edge
    /// continues through its opposite edge, matching physical pointer travel.
    /// Malformed cycles and missing display descriptors fail closed.
    public static func reachableDestination(
        from sourceDisplayID: DisplayID,
        edge sourceEdge: DisplayEdge,
        devices: [DeviceDescriptor],
        topology: DisplayTopology,
        availableDeviceIDs: Set<DeviceID>
    ) -> DisplayEndpoint? {
        resolveReachableDestination(
            from: sourceDisplayID,
            edge: sourceEdge,
            displaysByID: index(devices.flatMap(\.displays)),
            topology: topology,
            availableDeviceIDs: availableDeviceIDs
        )
    }

    private static func resolveReachableDestination(
        from sourceDisplayID: DisplayID,
        edge sourceEdge: DisplayEdge,
        displaysByID: [DisplayID: DisplayDescriptor],
        topology: DisplayTopology,
        availableDeviceIDs: Set<DeviceID>
    ) -> DisplayEndpoint? {
        var cursor = DisplayEndpoint(displayID: sourceDisplayID, edge: sourceEdge)
        var visited: Set<DisplayEndpoint> = []

        while visited.insert(cursor).inserted {
            guard let destination = topology.destination(
                from: cursor.displayID,
                edge: cursor.edge
            ), let display = displaysByID[destination.displayID] else { return nil }
            if availableDeviceIDs.contains(display.deviceID) { return destination }
            cursor = DisplayEndpoint(
                displayID: destination.displayID,
                edge: destination.edge.opposite
            )
        }
        return nil
    }

    private static func index(_ displays: [DisplayDescriptor]) -> [DisplayID: DisplayDescriptor] {
        var result: [DisplayID: DisplayDescriptor] = [:]
        for display in displays where result[display.id] == nil {
            result[display.id] = display
        }
        return result
    }

    private static func makeTransition(
        source: DisplayDescriptor,
        edge: DisplayEdge,
        x: Double,
        y: Double,
        localDeviceID: DeviceID,
        displays: [DisplayDescriptor],
        displaysByID: [DisplayID: DisplayDescriptor],
        topology: DisplayTopology,
        availableDeviceIDs: Set<DeviceID>?
    ) -> EdgeTransition? {
        let destination: DisplayEndpoint?
        if let availableDeviceIDs {
            destination = resolveReachableDestination(
                from: source.id,
                edge: edge,
                displaysByID: displaysByID,
                topology: topology,
                availableDeviceIDs: availableDeviceIDs
            )
        } else {
            destination = topology.destination(from: source.id, edge: edge)
        }
        guard let destination,
              let target = displays.first(where: { $0.id == destination.displayID }),
              target.deviceID != localDeviceID else { return nil }

        let normalized: Double
        switch edge {
        case .left, .right:
            normalized = (y - source.frame.minY) / max(source.frame.height, 1)
        case .top, .bottom:
            normalized = (x - source.frame.minX) / max(source.frame.width, 1)
        }
        return EdgeTransition(
            sourceDisplayID: source.id,
            sourceEdge: edge,
            targetDisplayID: target.id,
            targetDeviceID: target.deviceID,
            entryEdge: destination.edge,
            normalizedPosition: min(max(normalized, 0), 1)
        )
    }

    private static func isBeyond(
        _ edge: DisplayEdge,
        of frame: DisplayRect,
        x: Double,
        y: Double,
        tolerance: Double
    ) -> Bool {
        switch edge {
        case .left:
            x < frame.minX - tolerance && y >= frame.minY - tolerance && y <= frame.maxY + tolerance
        case .right:
            x > frame.maxX + tolerance && y >= frame.minY - tolerance && y <= frame.maxY + tolerance
        case .bottom:
            y < frame.minY - tolerance && x >= frame.minX - tolerance && x <= frame.maxX + tolerance
        case .top:
            y > frame.maxY + tolerance && x >= frame.minX - tolerance && x <= frame.maxX + tolerance
        }
    }

    private static func distance(
        to edge: DisplayEdge,
        of frame: DisplayRect,
        x: Double,
        y: Double
    ) -> Double {
        switch edge {
        case .left: frame.minX - x
        case .right: x - frame.maxX
        case .bottom: frame.minY - y
        case .top: y - frame.maxY
        }
    }
}
