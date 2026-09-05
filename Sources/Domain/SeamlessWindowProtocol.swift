import Foundation

public enum SeamlessWindowError: Error, Equatable, Sendable {
    case invalidMessage
    case unsupportedVersion
    case staleLease
    case busy
    case unavailable
    case permissionDenied
}

public enum SeamlessWindowLimits {
    public static let maximumFrameBytes = 2 * 1_024 * 1_024
    public static let maximumControlBytes = 16 * 1_024
    public static let maximumDimension = 4_096
    public static let maximumPixels = 4_096 * 2_160
    public static let leaseDuration: TimeInterval = 10
}

public struct RemoteWindowID: UUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Native window identifiers never cross the wire. Reopening the same native
/// window gets a fresh identity; every presentation has its own random epoch.
public struct WindowPresentationLease: Codable, Equatable, Sendable {
    public let windowID: RemoteWindowID
    public let epoch: UUID
    public let source: DeviceID
    public let destination: DeviceID

    public init(windowID: RemoteWindowID, source: DeviceID, destination: DeviceID, epoch: UUID = UUID()) {
        self.windowID = windowID
        self.epoch = epoch
        self.source = source
        self.destination = destination
    }
}

public struct SeamlessWindowDescriptor: Codable, Equatable, Sendable {
    public let id: RemoteWindowID
    public let title: String
    public let application: String
    public let width: Int
    public let height: Int

    public init(id: RemoteWindowID, title: String, application: String, width: Int, height: Int) {
        self.id = id; self.title = title; self.application = application
        self.width = width; self.height = height
    }

    public func validate() throws {
        guard title.utf8.count <= 1_024, application.utf8.count <= 256 else {
            throw SeamlessWindowError.invalidMessage
        }
        try Self.validateSize(width: width, height: height)
    }

    public static func validateSize(width: Int, height: Int) throws {
        guard width >= 16, height >= 16,
              width <= SeamlessWindowLimits.maximumDimension,
              height <= SeamlessWindowLimits.maximumDimension,
              width * height <= SeamlessWindowLimits.maximumPixels else {
            throw SeamlessWindowError.invalidMessage
        }
    }
}

public struct SeamlessInput: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case move, leftDown, leftUp, rightDown, rightUp, leftDrag, rightDrag
        case keyDown, keyUp, flagsChanged, scroll, releaseAll
    }
    public let kind: Kind
    public let x: Double
    public let y: Double
    public let keyCode: UInt16
    public let modifiers: UInt64
    public let deltaX: Double
    public let deltaY: Double

    public init(kind: Kind, x: Double = 0, y: Double = 0, keyCode: UInt16 = 0,
                modifiers: UInt64 = 0, deltaX: Double = 0, deltaY: Double = 0) {
        self.kind = kind; self.x = x; self.y = y; self.keyCode = keyCode
        self.modifiers = modifiers; self.deltaX = deltaX; self.deltaY = deltaY
    }

    public func validate() throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
              deltaX.isFinite, deltaY.isFinite, abs(deltaX) <= 4_096, abs(deltaY) <= 4_096,
              keyCode <= 127, modifiers & ~UInt64(0x00ff0000) == 0 else {
            throw SeamlessWindowError.invalidMessage
        }
    }
}

/// Control and encoded video have separate connections. This model never
/// contains raw CGEvent data, platform handles, or source filesystem paths.
public enum SeamlessWindowMessage: Codable, Equatable, Sendable {
    case offer(WindowPresentationLease, SeamlessWindowDescriptor)
    case accept(WindowPresentationLease)
    case reject(UUID)
    case release(UUID)
    case heartbeat(UUID)
    case input(UUID, SeamlessInput)
    case resize(UUID, Int, Int)
    case keyframe(UUID)
    case visibility(UUID, Bool)

    public func validate() throws {
        switch self {
        case let .offer(lease, descriptor):
            guard lease.source != lease.destination, lease.windowID == descriptor.id else {
                throw SeamlessWindowError.invalidMessage
            }
            try descriptor.validate()
        case let .input(_, event): try event.validate()
        case let .resize(_, width, height):
            try SeamlessWindowDescriptor.validateSize(width: width, height: height)
        default: break
        }
    }
}

/// H.264 AVCC access unit. Parameter sets travel with every frame so a receiver
/// can rebuild after reconnect. The keyframe flag is checked by the decoder.
public struct SeamlessVideoFrame: Codable, Equatable, Sendable {
    public let epoch: UUID
    public let sequence: UInt64
    public let width: Int
    public let height: Int
    public let keyframe: Bool
    public let sps: Data
    public let pps: Data
    public let bytes: Data

    public init(epoch: UUID, sequence: UInt64, width: Int, height: Int,
                keyframe: Bool, sps: Data, pps: Data, bytes: Data) {
        self.epoch = epoch; self.sequence = sequence; self.width = width; self.height = height
        self.keyframe = keyframe; self.sps = sps; self.pps = pps; self.bytes = bytes
    }

    public func validate() throws {
        try SeamlessWindowDescriptor.validateSize(width: width, height: height)
        guard !sps.isEmpty, sps.count <= 4_096, !pps.isEmpty, pps.count <= 4_096,
              sps.first.map({ $0 & 0x1f == 7 }) == true, pps.first.map({ $0 & 0x1f == 8 }) == true,
              !bytes.isEmpty, bytes.count <= SeamlessWindowLimits.maximumFrameBytes else {
            throw SeamlessWindowError.invalidMessage
        }
        var offset = 0
        var hasIDR = false
        while offset < bytes.count {
            guard bytes.count - offset >= 4 else { throw SeamlessWindowError.invalidMessage }
            let length = bytes.dropFirst(offset).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length > 0, length <= bytes.count - offset else { throw SeamlessWindowError.invalidMessage }
            if bytes[bytes.index(bytes.startIndex, offsetBy: offset)] & 0x1f == 5 { hasIDR = true }
            offset += length
        }
        guard keyframe == hasIDR else { throw SeamlessWindowError.invalidMessage }
    }
}
