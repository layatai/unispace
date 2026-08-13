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
        guard let source = displays.first(where: {
            $0.deviceID == localDeviceID
                && x >= $0.frame.minX - tolerance && x <= $0.frame.maxX + tolerance
                && y >= $0.frame.minY - tolerance && y <= $0.frame.maxY + tolerance
        }) else { return nil }

        let edge: DisplayEdge?
        if x <= source.frame.minX + tolerance { edge = .left }
        else if x >= source.frame.maxX - tolerance { edge = .right }
        else if y <= source.frame.minY + tolerance { edge = .bottom }
        else if y >= source.frame.maxY - tolerance { edge = .top }
        else { edge = nil }
        guard let edge,
              let destination = topology.destination(from: source.id, edge: edge),
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
}
