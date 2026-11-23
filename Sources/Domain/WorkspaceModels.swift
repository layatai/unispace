import Foundation
import Darwin

public enum PeerAddressError: Error, LocalizedError, Equatable {
    case empty
    case invalidFormat

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a Tailscale hostname or IP address."
        case .invalidFormat: "Enter a hostname or IP address without a URL, path, or port."
        }
    }
}

public struct PeerAddress: Codable, Hashable, Sendable, CustomStringConvertible {
    public let host: String

    public init(_ rawValue: String) throws {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw PeerAddressError.empty }
        if value.hasPrefix("["), value.hasSuffix("]") {
            value.removeFirst()
            value.removeLast()
        }
        guard !value.isEmpty,
              !value.contains("://"),
              value.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@")) == nil,
              Self.isIPAddress(value) || Self.isHostname(value) else {
            throw PeerAddressError.invalidFormat
        }
        host = value.lowercased()
    }

    public var description: String { host }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(host)
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
        }
    }

    private static func isHostname(_ value: String) -> Bool {
        guard value.utf8.count <= 253, !value.contains(":") else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty && labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0.value == 45
            }
        }
    }
}

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

public struct DeviceCapability: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            rawValue = value
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            rawValue = try legacy.decode(String.self, forKey: .rawValue)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private enum LegacyCodingKeys: String, CodingKey { case rawValue }

    public static let publicTrackpadGestures = Self(rawValue: "public-trackpad-gestures-v1")
    public static let portableTrackpadGestures = Self(rawValue: "portable-trackpad-gestures-v1")
    public static let crossPlatformInputV2 = Self(rawValue: "cross-platform-input-v2")
    public static let quicStreamV2 = Self(rawValue: "quic-stream-v2")
    public static let udpPointerV2 = Self(rawValue: "udp-pointer-v2")
    public static let activationAcknowledgementV1 = Self(rawValue: "activation-ack-v1")
    public static let realtimePointerProgressV1 = Self(rawValue: "realtime-pointer-progress-v1")
    public static let controlResilienceV1 = Self(rawValue: "control-resilience-v1")
    public static let workspacePresenceV1 = Self(rawValue: "workspace-presence-v1")
}

public struct DevicePlatform: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            rawValue = value
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            rawValue = try legacy.decode(String.self, forKey: .rawValue)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private enum LegacyCodingKeys: String, CodingKey { case rawValue }

    public static let unknown = Self(rawValue: "unknown")
    public static let macOS = Self(rawValue: "macos")
    public static let windows = Self(rawValue: "windows")
    public static let linux = Self(rawValue: "linux")

    /// Receiver platforms that use the portable v2 control/input wire format.
    public var isPortableReceiver: Bool {
        self == .windows || self == .linux
    }
}

public struct DeviceDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: DeviceID
    public var name: String
    public var displays: [DisplayDescriptor]
    public var peerAddresses: [PeerAddress]
    public var capabilities: Set<DeviceCapability>
    public var platform: DevicePlatform

    public init(
        id: DeviceID,
        name: String,
        displays: [DisplayDescriptor] = [],
        peerAddresses: [PeerAddress] = [],
        capabilities: Set<DeviceCapability> = [],
        platform: DevicePlatform = .unknown
    ) {
        self.id = id
        self.name = name
        self.displays = displays
        self.peerAddresses = peerAddresses
        self.capabilities = capabilities
        self.platform = platform
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case displays
        case peerAddresses
        case capabilities
        case platform
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(DeviceID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        displays = try container.decodeIfPresent([DisplayDescriptor].self, forKey: .displays) ?? []
        peerAddresses = try container.decodeIfPresent([PeerAddress].self, forKey: .peerAddresses) ?? []
        capabilities = try container.decodeIfPresent(Set<DeviceCapability>.self, forKey: .capabilities) ?? []
        platform = try container.decodeIfPresent(DevicePlatform.self, forKey: .platform) ?? .unknown
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

/// The latest membership decision for one device. Forgetting a device and
/// pairing it again are both recorded so replicas converge on whichever
/// happened last instead of resurrecting a forgotten device on merge.
public struct DeviceMembershipChange: Codable, Equatable, Sendable {
    public let deviceID: DeviceID
    public let removed: Bool
    /// Milliseconds since 1970 on the Mac that made the change.
    public let stamp: UInt64

    public init(deviceID: DeviceID, removed: Bool, stamp: UInt64) {
        self.deviceID = deviceID
        self.removed = removed
        self.stamp = stamp
    }

    public static func now() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1000))
    }

    /// Later stamp wins; on a tie, removal wins so a forget is never undone
    /// by a concurrent stale replica.
    func supersedes(_ other: DeviceMembershipChange) -> Bool {
        stamp != other.stamp ? stamp > other.stamp : removed && !other.removed
    }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public let id: WorkspaceID
    public var name: String
    public var localDeviceID: DeviceID
    public var devices: [DeviceDescriptor]
    public var topology: DisplayTopology
    public var generation: UInt64
    public var membershipChanges: [DeviceMembershipChange]

    public init(
        id: WorkspaceID,
        name: String,
        localDeviceID: DeviceID,
        devices: [DeviceDescriptor],
        topology: DisplayTopology = .init(),
        generation: UInt64 = 0,
        membershipChanges: [DeviceMembershipChange] = []
    ) {
        self.id = id
        self.name = name
        self.localDeviceID = localDeviceID
        self.devices = devices
        self.topology = topology
        self.generation = generation
        self.membershipChanges = membershipChanges
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, localDeviceID, devices, topology, generation, membershipChanges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WorkspaceID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        localDeviceID = try container.decode(DeviceID.self, forKey: .localDeviceID)
        devices = try container.decode([DeviceDescriptor].self, forKey: .devices)
        topology = try container.decode(DisplayTopology.self, forKey: .topology)
        generation = try container.decode(UInt64.self, forKey: .generation)
        membershipChanges = try container.decodeIfPresent(
            [DeviceMembershipChange].self,
            forKey: .membershipChanges
        ) ?? []
    }

    public func isForgotten(_ deviceID: DeviceID) -> Bool {
        membershipChanges.first { $0.deviceID == deviceID }?.removed == true
    }

    /// Removes a device and records the decision so merges, discovery and
    /// hellos cannot add it back until it is paired again.
    public mutating func forget(_ deviceID: DeviceID, stamp: UInt64 = DeviceMembershipChange.now()) {
        let removedDisplays = Set(devices.first { $0.id == deviceID }?.displays.map(\.id) ?? [])
        devices.removeAll { $0.id == deviceID }
        topology.links.removeAll {
            removedDisplays.contains($0.source.displayID) || removedDisplays.contains($0.destination.displayID)
        }
        record(DeviceMembershipChange(deviceID: deviceID, removed: true, stamp: stamp))
    }

    /// Adds or refreshes a device the user explicitly paired, clearing any
    /// earlier forget.
    public mutating func admit(_ device: DeviceDescriptor, stamp: UInt64 = DeviceMembershipChange.now()) {
        if isForgotten(device.id) || membershipChanges.contains(where: { $0.deviceID == device.id }) {
            record(DeviceMembershipChange(deviceID: device.id, removed: false, stamp: stamp))
        }
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }

    /// Keeps the winning change per device. Returns false when the change
    /// lost to a newer one already recorded.
    @discardableResult
    public mutating func record(_ change: DeviceMembershipChange) -> Bool {
        if let index = membershipChanges.firstIndex(where: { $0.deviceID == change.deviceID }) {
            guard change.supersedes(membershipChanges[index]) else { return false }
            membershipChanges[index] = change
        } else {
            membershipChanges.append(change)
        }
        return true
    }

    /// Replaces one Mac's current displays and removes topology links that can
    /// no longer be attributed safely. This deliberately drops a legacy link
    /// when its display ID was also used by another Mac.
    public mutating func updateDevice(_ device: DeviceDescriptor) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else {
            devices.append(device)
            return
        }

        let retiredDisplayIDs = Set(devices[index].displays.map(\.id))
            .subtracting(device.displays.map(\.id))
        topology.links.removeAll {
            retiredDisplayIDs.contains($0.source.displayID)
                || retiredDisplayIDs.contains($0.destination.displayID)
        }
        devices[index] = device

        let knownDisplayIDs = Set(devices.flatMap { $0.displays.map(\.id) })
        topology.links.removeAll {
            !knownDisplayIDs.contains($0.source.displayID)
                || !knownDisplayIDs.contains($0.destination.displayID)
        }
    }
}
