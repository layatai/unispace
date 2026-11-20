import Foundation

/// Local monotonic measurements; no cross-machine timestamp subtraction.
public struct InputQueueSnapshot: Codable, Equatable, Sendable {
    public let acceptedFrames: UInt64
    public let sentFrames: UInt64
    public let coalescedFrames: UInt64
    public let pendingFrames: Int
    public let maximumPendingFrames: Int
    public let oldestPendingAgeNanoseconds: UInt64
}
