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

public enum EdgeRouter {
    public static func transition(
        x: Double,
        y: Double,
        localDeviceID: DeviceID,
        devices: [DeviceDescriptor],
        topology: DisplayTopology,
        tolerance: Double = 1.5
    ) -> EdgeTransition? {
        let displays = devices.flatMap(\.displays)
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
                topology: topology
            )
        }

        let overshotEdges = localDisplays.flatMap { source in
            DisplayEdge.allCases.compactMap { edge -> (DisplayDescriptor, DisplayEdge, Double)? in
                guard topology.destination(from: source.id, edge: edge) != nil,
                      isBeyond(edge, of: source.frame, x: x, y: y, tolerance: tolerance) else { return nil }
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
            topology: topology
        )
    }

    private static func makeTransition(
        source: DisplayDescriptor,
        edge: DisplayEdge,
        x: Double,
        y: Double,
        localDeviceID: DeviceID,
        displays: [DisplayDescriptor],
        topology: DisplayTopology
    ) -> EdgeTransition? {
        guard let destination = topology.destination(from: source.id, edge: edge),
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
