import Foundation
import UniSpaceDomain

@MainActor
public protocol SeamlessInputTarget: AnyObject {
    var isAvailable: Bool { get }
    func send(_ input: SeamlessInput) throws
    func releaseAll()
}

@MainActor
public protocol SeamlessCaptureSource: AnyObject {
    func catalog() async throws -> [SeamlessWindowDescriptor]
    func inputTarget(for id: RemoteWindowID) throws -> any SeamlessInputTarget
    func start(id: RemoteWindowID, epoch: UUID,
               onFrame: @escaping @MainActor @Sendable (SeamlessVideoFrame) -> Bool,
               onFailure: @escaping @MainActor @Sendable () -> Void) async throws
    func requestKeyframe()
    func setPaused(_ paused: Bool)
    func stop() async
}

/// Source-authoritative, one-window lease. Uses monotonic local time; peer wall
/// clocks and peer-supplied expiry values never affect ownership.
public struct WindowPresentationState: Sendable {
    public enum Phase: Equatable, Sendable { case idle, offered, presenting }
    public private(set) var phase = Phase.idle
    public private(set) var lease: WindowPresentationLease?
    private var deadline: TimeInterval = 0
    private var lastFrame: UInt64?

    public init() {}

    public mutating func offer(_ lease: WindowPresentationLease, now: TimeInterval) throws {
        guard phase == .idle else { throw SeamlessWindowError.busy }
        guard now.isFinite, lease.source != lease.destination else { throw SeamlessWindowError.invalidMessage }
        self.lease = lease
        phase = .offered
        deadline = now + SeamlessWindowLimits.leaseDuration
        lastFrame = nil
    }

    public mutating func accept(_ lease: WindowPresentationLease, now: TimeInterval) throws {
        guard self.lease == lease, phase == .offered, now.isFinite, now < deadline else {
            throw SeamlessWindowError.staleLease
        }
        phase = .presenting
        deadline = now + SeamlessWindowLimits.leaseDuration
    }

    public mutating func renew(epoch: UUID, now: TimeInterval) throws {
        guard phase == .presenting, lease?.epoch == epoch, now.isFinite, now < deadline else {
            throw SeamlessWindowError.staleLease
        }
        deadline = now + SeamlessWindowLimits.leaseDuration
    }

    public func authorizes(epoch: UUID, peer: DeviceID, now: TimeInterval) -> Bool {
        phase == .presenting && lease?.epoch == epoch && lease?.destination == peer && now.isFinite && now < deadline
    }

    public mutating func receive(_ frame: SeamlessVideoFrame) throws {
        try frame.validate()
        guard phase == .presenting, lease?.epoch == frame.epoch,
              lastFrame.map({ frame.sequence > $0 && (frame.sequence == $0 + 1 || frame.keyframe) }) ?? frame.keyframe else {
            throw SeamlessWindowError.staleLease
        }
        lastFrame = frame.sequence
    }

    @discardableResult public mutating func expire(now: TimeInterval) -> Bool {
        guard phase != .idle, !now.isFinite || now >= deadline else { return false }
        release()
        return true
    }

    public mutating func release() {
        phase = .idle; lease = nil; deadline = 0; lastFrame = nil
    }
}

public enum SeamlessWindowCodec {
    public static func encode(_ message: SeamlessWindowMessage) throws -> Data {
        try message.validate()
        let data = try PropertyListEncoder().encode(message)
        guard data.count <= SeamlessWindowLimits.maximumControlBytes else { throw SeamlessWindowError.invalidMessage }
        return data
    }

    public static func decode(_ data: Data) throws -> SeamlessWindowMessage {
        guard data.count <= SeamlessWindowLimits.maximumControlBytes else { throw SeamlessWindowError.invalidMessage }
        let value = try PropertyListDecoder().decode(SeamlessWindowMessage.self, from: data)
        try value.validate()
        return value
    }

    public static func encode(_ frame: SeamlessVideoFrame) throws -> Data {
        try frame.validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(frame)
        guard data.count <= SeamlessWindowLimits.maximumFrameBytes + 16_384 else { throw SeamlessWindowError.invalidMessage }
        return data
    }

    public static func decodeFrame(_ data: Data) throws -> SeamlessVideoFrame {
        guard data.count <= SeamlessWindowLimits.maximumFrameBytes + 16_384 else { throw SeamlessWindowError.invalidMessage }
        let value = try PropertyListDecoder().decode(SeamlessVideoFrame.self, from: data)
        try value.validate()
        return value
    }
}
