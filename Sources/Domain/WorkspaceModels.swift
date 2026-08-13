import Foundation

public struct DisplayRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
}

public struct DisplayDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: DisplayID
    public let deviceID: DeviceID
    public var name: String
    public var frame: DisplayRect
    public var scaleFactor: Double
    public var isMain: Bool

    public init(
        id: DisplayID,
        deviceID: DeviceID,
        name: String,
        frame: DisplayRect,
        scaleFactor: Double,
        isMain: Bool
    ) {
        self.id = id
        self.deviceID = deviceID
        self.name = name
        self.frame = frame
        self.scaleFactor = scaleFactor
        self.isMain = isMain
    }
}

public struct DeviceDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: DeviceID
    public var name: String
    public var displays: [DisplayDescriptor]

    public init(id: DeviceID, name: String, displays: [DisplayDescriptor] = []) {
        self.id = id
        self.name = name
        self.displays = displays
    }
}

public enum DisplayEdge: String, Codable, CaseIterable, Hashable, Sendable {
    case left
    case right
    case top
    case bottom

    public var opposite: DisplayEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }
}

public struct DisplayEndpoint: Codable, Hashable, Sendable {
    public let displayID: DisplayID
    public let edge: DisplayEdge

    public init(displayID: DisplayID, edge: DisplayEdge) {
        self.displayID = displayID
        self.edge = edge
    }
}

public struct EdgeLink: Codable, Hashable, Identifiable, Sendable {
    public let source: DisplayEndpoint
    public let destination: DisplayEndpoint

    public init(source: DisplayEndpoint, destination: DisplayEndpoint) {
        self.source = source
        self.destination = destination
    }

    public var id: String {
        "\(source.displayID)-\(source.edge.rawValue)-\(destination.displayID)-\(destination.edge.rawValue)"
    }
}

public struct DisplayTopology: Codable, Equatable, Sendable {
    public var links: [EdgeLink]

    public init(links: [EdgeLink] = []) {
        self.links = links
    }

    public func destination(from displayID: DisplayID, edge: DisplayEdge) -> DisplayEndpoint? {
        links.first { $0.source == DisplayEndpoint(displayID: displayID, edge: edge) }?.destination
    }

    public mutating func connect(_ first: DisplayEndpoint, to second: DisplayEndpoint) {
        disconnect(first)
        disconnect(second)
        links.append(EdgeLink(source: first, destination: second))
        links.append(EdgeLink(source: second, destination: first))
    }

    public mutating func disconnect(_ endpoint: DisplayEndpoint) {
        let linked = links.filter { $0.source == endpoint || $0.destination == endpoint }
        let affected = Set(linked.flatMap { [$0.source, $0.destination] })
        links.removeAll { affected.contains($0.source) || affected.contains($0.destination) }
    }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public let id: WorkspaceID
    public var name: String
    public var localDeviceID: DeviceID
    public var devices: [DeviceDescriptor]
    public var topology: DisplayTopology
    public var generation: UInt64

    public init(
        id: WorkspaceID,
        name: String,
        localDeviceID: DeviceID,
        devices: [DeviceDescriptor],
        topology: DisplayTopology = .init(),
        generation: UInt64 = 0
    ) {
        self.id = id
        self.name = name
        self.localDeviceID = localDeviceID
        self.devices = devices
        self.topology = topology
        self.generation = generation
    }
}
