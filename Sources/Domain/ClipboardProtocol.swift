import Foundation

public struct ClipboardPayloadID: UUIDIdentifier, Comparable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

public extension DeviceCapability {
    static let clipboardTextV1 = Self(rawValue: "clipboard-text-v1")
    static let clipboardURLV1 = Self(rawValue: "clipboard-url-v1")
}

public struct ClipboardLimits: Codable, Equatable, Sendable {
    public static let `default` = Self()

    public var maximumRepresentations: Int
    public var maximumRepresentationBytes: Int
    public var maximumPayloadBytes: Int
    public var recentPayloadCapacity: Int
    public var recentPayloadLifetime: TimeInterval

    public init(
        maximumRepresentations: Int = 4,
        maximumRepresentationBytes: Int = 256 * 1_024,
        maximumPayloadBytes: Int = 512 * 1_024,
        recentPayloadCapacity: Int = 256,
        recentPayloadLifetime: TimeInterval = 2 * 60
    ) {
        self.maximumRepresentations = maximumRepresentations
        self.maximumRepresentationBytes = maximumRepresentationBytes
        self.maximumPayloadBytes = maximumPayloadBytes
        self.recentPayloadCapacity = recentPayloadCapacity
        self.recentPayloadLifetime = recentPayloadLifetime
    }
}

public enum ClipboardRepresentationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case plainText
    case url
}

public enum ClipboardProtocolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(UInt16)
    case emptyPayload
    case tooManyRepresentations(Int)
    case duplicateRepresentation(ClipboardRepresentationKind)
    case invalidRepresentation(ClipboardRepresentationKind)
    case representationTooLarge(ClipboardRepresentationKind)
    case payloadTooLarge(Int)
    case invalidRevision
    case invalidDigest
    case originMismatch
    case workspaceMismatch
    case peerMismatch
    case malformedEnvelope

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "Unsupported clipboard protocol version \(version)."
        case .emptyPayload:
            "The clipboard does not contain supported text or link data."
        case .tooManyRepresentations:
            "The clipboard contains too many representations."
        case .duplicateRepresentation:
            "The clipboard contains duplicate representations."
        case .invalidRepresentation:
            "The clipboard contains an invalid representation."
        case .representationTooLarge, .payloadTooLarge:
            "The clipboard content exceeds the configured size limit."
        case .invalidRevision:
            "The clipboard update has an invalid revision."
        case .invalidDigest:
            "The clipboard update failed its integrity check."
        case .originMismatch, .peerMismatch:
            "The clipboard update came from an unexpected device."
        case .workspaceMismatch:
            "The clipboard update belongs to a different workspace."
        case .malformedEnvelope:
            "The clipboard update is malformed."
        }
    }
}

public struct ClipboardRepresentation: Codable, Equatable, Hashable, Sendable {
    public let kind: ClipboardRepresentationKind
    public let value: String

    public init(kind: ClipboardRepresentationKind, value: String) {
        self.kind = kind
        self.value = value
    }

    public func normalized() -> Self {
        let normalizedValue: String
        switch kind {
        case .plainText:
            normalizedValue = value
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .precomposedStringWithCanonicalMapping
        case .url:
            normalizedValue = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
        }
        return Self(kind: kind, value: normalizedValue)
    }

    @discardableResult
    public func validated(limits: ClipboardLimits = .default) throws -> Self {
        let normalized = normalized()
        guard self == normalized,
              !value.isEmpty,
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ClipboardProtocolError.invalidRepresentation(kind)
        }
        guard value.utf8.count <= limits.maximumRepresentationBytes else {
            throw ClipboardProtocolError.representationTooLarge(kind)
        }
        if kind == .url {
            guard let components = URLComponents(string: value),
                  let scheme = components.scheme,
                  !scheme.isEmpty,
                  components.url?.isFileURL != true else {
                throw ClipboardProtocolError.invalidRepresentation(kind)
            }
        }
        return self
    }
}

public struct ClipboardPayload: Codable, Equatable, Sendable {
    public let payloadID: ClipboardPayloadID
    public let originDeviceID: DeviceID
    public let revision: UInt64
    public let timestamp: Date
    public let contentHash: Data
    public let representations: [ClipboardRepresentation]

    public init(
        payloadID: ClipboardPayloadID = ClipboardPayloadID(),
        originDeviceID: DeviceID,
        revision: UInt64,
        timestamp: Date = Date(),
        contentHash: Data,
        representations: [ClipboardRepresentation]
    ) {
        self.payloadID = payloadID
        self.originDeviceID = originDeviceID
        self.revision = revision
        self.timestamp = timestamp
        self.contentHash = contentHash
        self.representations = representations
    }

    public var plainText: String? {
        representations.first(where: { $0.kind == .plainText })?.value
    }

    public var url: String? {
        representations.first(where: { $0.kind == .url })?.value
    }

    @discardableResult
    public func validated(limits: ClipboardLimits = .default) throws -> Self {
        guard revision > 0 else { throw ClipboardProtocolError.invalidRevision }
        guard contentHash.count == 32 else { throw ClipboardProtocolError.invalidDigest }
        guard !representations.isEmpty else { throw ClipboardProtocolError.emptyPayload }
        guard representations.count <= limits.maximumRepresentations else {
            throw ClipboardProtocolError.tooManyRepresentations(representations.count)
        }

        var kinds = Set<ClipboardRepresentationKind>()
        var totalBytes = 0
        for representation in representations {
            try representation.validated(limits: limits)
            guard kinds.insert(representation.kind).inserted else {
                throw ClipboardProtocolError.duplicateRepresentation(representation.kind)
            }
            let (next, overflow) = totalBytes.addingReportingOverflow(representation.value.utf8.count)
            guard !overflow, next <= limits.maximumPayloadBytes else {
                throw ClipboardProtocolError.payloadTooLarge(overflow ? Int.max : next)
            }
            totalBytes = next
        }

        guard representations == representations.sorted(by: Self.representationOrder) else {
            throw ClipboardProtocolError.invalidRepresentation(representations[0].kind)
        }
        return self
    }

    public static func normalizedRepresentations(
        _ values: [ClipboardRepresentation],
        limits: ClipboardLimits = .default
    ) throws -> [ClipboardRepresentation] {
        let normalized = values.map { $0.normalized() }
            .filter { !$0.value.isEmpty }
            .sorted(by: representationOrder)
        let provisional = ClipboardPayload(
            originDeviceID: DeviceID(),
            revision: 1,
            contentHash: Data(repeating: 0, count: 32),
            representations: normalized
        )
        try provisional.validated(limits: limits)
        return normalized
    }

    public static func canonicalContentData(
        for representations: [ClipboardRepresentation]
    ) -> Data {
        var data = Data()
        for representation in representations.sorted(by: representationOrder) {
            let kindBytes = Data(representation.kind.rawValue.utf8)
            let valueBytes = Data(representation.value.utf8)
            data.appendPortableUInt32(UInt32(kindBytes.count))
            data.append(kindBytes)
            data.appendPortableUInt32(UInt32(valueBytes.count))
            data.append(valueBytes)
        }
        return data
    }

    private static func representationOrder(
        _ lhs: ClipboardRepresentation,
        _ rhs: ClipboardRepresentation
    ) -> Bool {
        lhs.kind.rawValue < rhs.kind.rawValue
    }
}

public struct ClipboardEnvelope: Codable, Equatable, Sendable {
    public static let protocolVersion: UInt16 = 1

    public let version: UInt16
    public let workspaceID: WorkspaceID
    public let senderDeviceID: DeviceID
    public let payload: ClipboardPayload

    public init(
        version: UInt16 = Self.protocolVersion,
        workspaceID: WorkspaceID,
        senderDeviceID: DeviceID,
        payload: ClipboardPayload
    ) {
        self.version = version
        self.workspaceID = workspaceID
        self.senderDeviceID = senderDeviceID
        self.payload = payload
    }

    @discardableResult
    public func validated(
        workspaceID expectedWorkspaceID: WorkspaceID,
        senderDeviceID expectedSenderDeviceID: DeviceID,
        limits: ClipboardLimits = .default
    ) throws -> Self {
        guard version == Self.protocolVersion else {
            throw ClipboardProtocolError.unsupportedVersion(version)
        }
        guard workspaceID == expectedWorkspaceID else {
            throw ClipboardProtocolError.workspaceMismatch
        }
        guard senderDeviceID == expectedSenderDeviceID else {
            throw ClipboardProtocolError.peerMismatch
        }
        guard payload.originDeviceID == expectedSenderDeviceID else {
            throw ClipboardProtocolError.originMismatch
        }
        try payload.validated(limits: limits)
        return self
    }
}

private extension Data {
    mutating func appendPortableUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
