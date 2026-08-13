import Foundation

public protocol UUIDIdentifier: Codable, Hashable, Sendable, CustomStringConvertible {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

public extension UUIDIdentifier {
    var description: String { rawValue.uuidString }
}

public struct DeviceID: UUIDIdentifier, Comparable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public static func < (lhs: DeviceID, rhs: DeviceID) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

public struct WorkspaceID: UUIDIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct DisplayID: UUIDIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct SessionID: UUIDIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}
