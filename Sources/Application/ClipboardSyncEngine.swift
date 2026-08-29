import CryptoKit
import Foundation
import UniSpaceDomain

public struct ClipboardOrderingKey: Comparable, Equatable, Sendable {
    public let revision: UInt64
    public let originDeviceID: DeviceID

    public init(revision: UInt64, originDeviceID: DeviceID) {
        self.revision = revision
        self.originDeviceID = originDeviceID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
        return lhs.originDeviceID < rhs.originDeviceID
    }
}

public struct ClipboardSyncEngine: Sendable {
    private var localDeviceID: DeviceID
    private let limits: ClipboardLimits
    private var logicalClock: UInt64 = 0
    private var latestOrderingKey: ClipboardOrderingKey?
    private var recentPayloads: [ClipboardPayloadID: Date] = [:]
    private var recentContentHashes: [Data: Date] = [:]

    public init(
        localDeviceID: DeviceID,
        limits: ClipboardLimits = .default
    ) {
        self.localDeviceID = localDeviceID
        self.limits = limits
    }

    public var recentPayloadCount: Int { recentPayloads.count }
    public var currentOrderingKey: ClipboardOrderingKey? { latestOrderingKey }

    public mutating func makeLocalPayload(
        representations: [ClipboardRepresentation],
        now: Date = Date()
    ) throws -> ClipboardPayload? {
        prune(now: now)
        let normalized = try ClipboardPayload.normalizedRepresentations(
            representations,
            limits: limits
        )
        let hash = Self.contentHash(for: normalized)

        let wallClockSeed = UInt64(max(0, now.timeIntervalSince1970 * 1_000_000))
        let baseline = max(logicalClock, latestOrderingKey?.revision ?? 0, wallClockSeed)
        let (revision, overflow) = baseline.addingReportingOverflow(1)
        guard !overflow, revision > 0 else { throw ClipboardProtocolError.invalidRevision }

        let payload = ClipboardPayload(
            originDeviceID: localDeviceID,
            revision: revision,
            timestamp: now,
            contentHash: hash,
            representations: normalized
        )
        try payload.validated(limits: limits)
        logicalClock = revision
        latestOrderingKey = ClipboardOrderingKey(
            revision: revision,
            originDeviceID: localDeviceID
        )
        remember(payload, now: now)
        return payload
    }

    public mutating func acceptRemote(
        _ payload: ClipboardPayload,
        from peerDeviceID: DeviceID,
        now: Date = Date()
    ) throws -> Bool {
        try payload.validated(limits: limits)
        guard payload.originDeviceID == peerDeviceID else {
            throw ClipboardProtocolError.originMismatch
        }
        let expectedHash = Self.contentHash(for: payload.representations)
        guard expectedHash == payload.contentHash else {
            throw ClipboardProtocolError.invalidDigest
        }

        prune(now: now)
        logicalClock = max(logicalClock, payload.revision)
        if recentPayloads[payload.payloadID] != nil { return false }

        let orderingKey = ClipboardOrderingKey(
            revision: payload.revision,
            originDeviceID: payload.originDeviceID
        )
        remember(payload, now: now)
        guard latestOrderingKey == nil || orderingKey > latestOrderingKey! else {
            return false
        }

        latestOrderingKey = orderingKey
        return true
    }

    public mutating func reset(localDeviceID: DeviceID? = nil) {
        if let localDeviceID { self.localDeviceID = localDeviceID }
        logicalClock = 0
        latestOrderingKey = nil
        recentPayloads.removeAll(keepingCapacity: false)
        recentContentHashes.removeAll(keepingCapacity: false)
    }

    public mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-limits.recentPayloadLifetime)
        recentPayloads = recentPayloads.filter { $0.value >= cutoff }
        recentContentHashes = recentContentHashes.filter { $0.value >= cutoff }
        trim(&recentPayloads, capacity: limits.recentPayloadCapacity)
        trim(&recentContentHashes, capacity: limits.recentPayloadCapacity)
    }

    public static func contentHash(
        for representations: [ClipboardRepresentation]
    ) -> Data {
        Data(SHA256.hash(data: ClipboardPayload.canonicalContentData(for: representations)))
    }

    private mutating func remember(_ payload: ClipboardPayload, now: Date) {
        recentPayloads[payload.payloadID] = now
        recentContentHashes[payload.contentHash] = now
        trim(&recentPayloads, capacity: limits.recentPayloadCapacity)
        trim(&recentContentHashes, capacity: limits.recentPayloadCapacity)
    }

    private func trim<Key: Hashable>(
        _ values: inout [Key: Date],
        capacity: Int
    ) {
        guard capacity >= 0, values.count > capacity else { return }
        let removeCount = values.count - capacity
        for key in values.sorted(by: { $0.value < $1.value }).prefix(removeCount).map(\.key) {
            values.removeValue(forKey: key)
        }
    }
}
