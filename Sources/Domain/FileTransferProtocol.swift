import Foundation

public struct TransferID: UUIDIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TransferEntryID: UUIDIdentifier, Comparable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

public extension DeviceCapability {
    static let fileTransferV1 = Self(rawValue: "file-transfer-v1")
}

public struct FileTransferLimits: Codable, Equatable, Sendable {
    public static let `default` = Self()

    public var maximumManifestEntries: Int
    public var maximumFilenameBytes: Int
    public var defaultChunkSize: Int
    public var maximumChunkSize: Int
    public var maximumTransferBytes: UInt64
    public var acknowledgementIntervalBytes: UInt64
    public var partialRetentionSeconds: TimeInterval
    public var completedRetentionSeconds: TimeInterval

    public init(
        maximumManifestEntries: Int = 1_000,
        maximumFilenameBytes: Int = 255,
        defaultChunkSize: Int = 256 * 1_024,
        maximumChunkSize: Int = 1_024 * 1_024,
        maximumTransferBytes: UInt64 = 1_099_511_627_776,
        acknowledgementIntervalBytes: UInt64 = 1_024 * 1_024,
        partialRetentionSeconds: TimeInterval = 7 * 24 * 60 * 60,
        completedRetentionSeconds: TimeInterval = 24 * 60 * 60
    ) {
        self.maximumManifestEntries = maximumManifestEntries
        self.maximumFilenameBytes = maximumFilenameBytes
        self.defaultChunkSize = defaultChunkSize
        self.maximumChunkSize = maximumChunkSize
        self.maximumTransferBytes = maximumTransferBytes
        self.acknowledgementIntervalBytes = acknowledgementIntervalBytes
        self.partialRetentionSeconds = partialRetentionSeconds
        self.completedRetentionSeconds = completedRetentionSeconds
    }
}

public enum FileTransferDirection: String, Codable, Equatable, Sendable {
    case incoming
    case outgoing
}

public enum FileTransferState: String, Codable, CaseIterable, Equatable, Sendable {
    case offered
    case awaitingAcceptance
    case preparing
    case transferring
    case paused
    case verifying
    case completed
    case cancelled
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: true
        default: false
        }
    }

    public func canTransition(to destination: Self) -> Bool {
        if self == destination { return true }
        switch (self, destination) {
        case (.offered, .awaitingAcceptance),
             (.offered, .cancelled),
             (.offered, .failed),
             (.awaitingAcceptance, .preparing),
             (.awaitingAcceptance, .cancelled),
             (.awaitingAcceptance, .failed),
             (.preparing, .transferring),
             (.preparing, .cancelled),
             (.preparing, .failed),
             (.transferring, .paused),
             (.transferring, .verifying),
             (.transferring, .cancelled),
             (.transferring, .failed),
             (.paused, .transferring),
             (.paused, .cancelled),
             (.paused, .failed),
             (.verifying, .completed),
             (.verifying, .cancelled),
             (.verifying, .failed),
             (.failed, .preparing),
             (.failed, .cancelled):
            true
        default:
            false
        }
    }
}

public enum FileTransferFailureCode: String, Codable, Equatable, Sendable {
    case unsupportedPeer
    case transferRejected
    case manifestInvalid
    case fileUnavailable
    case sourceChanged
    case invalidOffset
    case sizeLimitExceeded
    case insufficientStorage
    case hashMismatch
    case contentChannelUnavailable
    case cancelled
    case resumeRejected
    case stagingFailure
    case permissionFailure
    case protocolViolation
    case timedOut
    case unknown
}

public enum FileTransferProtocolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(UInt16)
    case emptyManifest
    case tooManyEntries(Int)
    case transferTooLarge(UInt64)
    case invalidFilename(String)
    case duplicateEntry(TransferEntryID)
    case duplicateFilename(String)
    case invalidDigest(TransferEntryID)
    case invalidFileSize(TransferEntryID)
    case invalidChunkSize(Int)
    case invalidOffset(entryID: TransferEntryID, offset: UInt64)
    case chunkExceedsEntry(entryID: TransferEntryID)
    case unknownEntry(TransferEntryID)
    case workspaceMismatch
    case peerMismatch
    case malformedEnvelope

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "Unsupported file-transfer protocol version \(version)."
        case .emptyManifest:
            "The transfer does not contain any files."
        case .tooManyEntries:
            "The transfer contains too many files."
        case .transferTooLarge:
            "The transfer exceeds the configured size limit."
        case .invalidFilename:
            "A file has an invalid name."
        case .duplicateEntry, .duplicateFilename:
            "The transfer contains duplicate files."
        case .invalidDigest:
            "A file has an invalid integrity digest."
        case .invalidFileSize:
            "A file has an invalid size."
        case .invalidChunkSize:
            "A transfer chunk has an invalid size."
        case .invalidOffset, .chunkExceedsEntry:
            "A transfer chunk has an invalid offset."
        case .unknownEntry:
            "A transfer references an unknown file."
        case .workspaceMismatch, .peerMismatch:
            "The transfer does not belong to this trusted workspace or peer."
        case .malformedEnvelope:
            "The transfer message is malformed."
        }
    }
}

public struct TransferManifestEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: TransferEntryID
    public let filename: String
    public let contentTypeIdentifier: String?
    public let byteCount: UInt64
    public let sha256: Data
    public let modificationDate: Date?

    public init(
        id: TransferEntryID = TransferEntryID(),
        filename: String,
        contentTypeIdentifier: String? = nil,
        byteCount: UInt64,
        sha256: Data,
        modificationDate: Date? = nil
    ) {
        self.id = id
        self.filename = filename
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.sha256 = sha256
        self.modificationDate = modificationDate
    }

    public func validated(limits: FileTransferLimits = .default) throws -> Self {
        let normalized = filename.precomposedStringWithCanonicalMapping
        let invalidScalars = CharacterSet.controlCharacters.union(.illegalCharacters)
        guard filename == normalized,
              !filename.isEmpty,
              filename != ".",
              filename != "..",
              filename.utf8.count <= limits.maximumFilenameBytes,
              filename.rangeOfCharacter(from: invalidScalars) == nil,
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.contains("\0") else {
            throw FileTransferProtocolError.invalidFilename(filename)
        }
        guard sha256.count == 32 else {
            throw FileTransferProtocolError.invalidDigest(id)
        }
        guard byteCount <= limits.maximumTransferBytes else {
            throw FileTransferProtocolError.invalidFileSize(id)
        }
        return self
    }
}

public struct TransferManifest: Codable, Equatable, Sendable {
    public let transferID: TransferID
    public let workspaceID: WorkspaceID
    public let sourceDeviceID: DeviceID
    public let destinationDeviceID: DeviceID
    public let entries: [TransferManifestEntry]
    public let createdAt: Date

    public init(
        transferID: TransferID = TransferID(),
        workspaceID: WorkspaceID,
        sourceDeviceID: DeviceID,
        destinationDeviceID: DeviceID,
        entries: [TransferManifestEntry],
        createdAt: Date = Date()
    ) {
        self.transferID = transferID
        self.workspaceID = workspaceID
        self.sourceDeviceID = sourceDeviceID
        self.destinationDeviceID = destinationDeviceID
        self.entries = entries
        self.createdAt = createdAt
    }

    public var totalByteCount: UInt64 {
        entries.reduce(0) { partial, entry in
            let (sum, overflow) = partial.addingReportingOverflow(entry.byteCount)
            return overflow ? UInt64.max : sum
        }
    }

    public var displayName: String {
        if entries.count == 1 { return entries[0].filename }
        return "\(entries.count) files"
    }

    public func entry(id: TransferEntryID) -> TransferManifestEntry? {
        entries.first { $0.id == id }
    }

    public func validated(limits: FileTransferLimits = .default) throws -> Self {
        guard !entries.isEmpty else { throw FileTransferProtocolError.emptyManifest }
        guard entries.count <= limits.maximumManifestEntries else {
            throw FileTransferProtocolError.tooManyEntries(entries.count)
        }

        var ids = Set<TransferEntryID>()
        var names = Set<String>()
        var total: UInt64 = 0
        for entry in entries {
            _ = try entry.validated(limits: limits)
            guard ids.insert(entry.id).inserted else {
                throw FileTransferProtocolError.duplicateEntry(entry.id)
            }
            let foldedName = entry.filename.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard names.insert(foldedName).inserted else {
                throw FileTransferProtocolError.duplicateFilename(entry.filename)
            }
            let (next, overflow) = total.addingReportingOverflow(entry.byteCount)
            guard !overflow, next <= limits.maximumTransferBytes else {
                throw FileTransferProtocolError.transferTooLarge(next)
            }
            total = next
        }
        return self
    }
}

public struct TransferEntryOffset: Codable, Equatable, Sendable {
    public let entryID: TransferEntryID
    public let offset: UInt64

    public init(entryID: TransferEntryID, offset: UInt64) {
        self.entryID = entryID
        self.offset = offset
    }
}

public struct TransferOffer: Codable, Equatable, Sendable {
    public let manifest: TransferManifest

    public init(manifest: TransferManifest) {
        self.manifest = manifest
    }
}

public struct TransferRequest: Codable, Equatable, Sendable {
    public let transferID: TransferID
    public let offsets: [TransferEntryOffset]

    public init(transferID: TransferID, offsets: [TransferEntryOffset]) {
        self.transferID = transferID
        self.offsets = offsets
    }
}

public struct TransferChunk: Codable, Equatable, Sendable {
    public let transferID: TransferID
    public let entryID: TransferEntryID
    public let offset: UInt64
    public let data: Data

    public init(transferID: TransferID, entryID: TransferEntryID, offset: UInt64, data: Data) {
        self.transferID = transferID
        self.entryID = entryID
        self.offset = offset
        self.data = data
    }

    public func validated(
        against manifest: TransferManifest,
        limits: FileTransferLimits = .default
    ) throws -> Self {
        guard !data.isEmpty, data.count <= limits.maximumChunkSize else {
            throw FileTransferProtocolError.invalidChunkSize(data.count)
        }
        guard let entry = manifest.entry(id: entryID) else {
            throw FileTransferProtocolError.unknownEntry(entryID)
        }
        guard offset <= entry.byteCount else {
            throw FileTransferProtocolError.invalidOffset(entryID: entryID, offset: offset)
        }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(data.count))
        guard !overflow, end <= entry.byteCount else {
            throw FileTransferProtocolError.chunkExceedsEntry(entryID: entryID)
        }
        return self
    }
}

public struct TransferAcknowledgement: Codable, Equatable, Sendable {
    public let transferID: TransferID
    public let entryID: TransferEntryID
    public let verifiedOffset: UInt64

    public init(transferID: TransferID, entryID: TransferEntryID, verifiedOffset: UInt64) {
        self.transferID = transferID
        self.entryID = entryID
        self.verifiedOffset = verifiedOffset
    }
}

public struct TransferEntryCompletion: Codable, Equatable, Sendable {
    public let transferID: TransferID
    public let entryID: TransferEntryID

    public init(transferID: TransferID, entryID: TransferEntryID) {
        self.transferID = transferID
        self.entryID = entryID
    }
}

public struct TransferCompletion: Codable, Equatable, Sendable {
    public let transferID: TransferID

    public init(transferID: TransferID) {
        self.transferID = transferID
    }
}

public struct TransferVerification: Codable, Equatable, Sendable {
    public let transferID: TransferID
    public let accepted: Bool
    public let failureCode: FileTransferFailureCode?

    public init(
        transferID: TransferID,
        accepted: Bool,
        failureCode: FileTransferFailureCode? = nil
    ) {
        self.transferID = transferID
        self.accepted = accepted
        self.failureCode = failureCode
    }
}

public struct TransferCancellation: Codable, Equatable, Sendable {
    public let transferID: TransferID
    public let reason: FileTransferFailureCode

    public init(transferID: TransferID, reason: FileTransferFailureCode = .cancelled) {
        self.transferID = transferID
        self.reason = reason
    }
}

public struct TransferResumeQuery: Codable, Equatable, Sendable {
    public let transferID: TransferID

    public init(transferID: TransferID) {
        self.transferID = transferID
    }
}

public struct TransferResumeState: Codable, Equatable, Sendable {
    public let transferID: TransferID
    public let offsets: [TransferEntryOffset]
    public let completed: Bool

    public init(transferID: TransferID, offsets: [TransferEntryOffset], completed: Bool = false) {
        self.transferID = transferID
        self.offsets = offsets
        self.completed = completed
    }
}

public struct TransferFailure: Codable, Equatable, Sendable {
    public let transferID: TransferID
    public let code: FileTransferFailureCode

    public init(transferID: TransferID, code: FileTransferFailureCode) {
        self.transferID = transferID
        self.code = code
    }
}

public enum FileTransferMessage: Codable, Equatable, Sendable {
    case offer(TransferOffer)
    case request(TransferRequest)
    case chunk(TransferChunk)
    case acknowledgement(TransferAcknowledgement)
    case entryComplete(TransferEntryCompletion)
    case transferComplete(TransferCompletion)
    case verification(TransferVerification)
    case cancellation(TransferCancellation)
    case resumeQuery(TransferResumeQuery)
    case resumeState(TransferResumeState)
    case failure(TransferFailure)
}

public struct FileTransferEnvelope: Codable, Equatable, Sendable {
    public static let protocolVersion: UInt16 = 1

    public let version: UInt16
    public let workspaceID: WorkspaceID
    public let senderDeviceID: DeviceID
    public let message: FileTransferMessage

    public init(
        version: UInt16 = Self.protocolVersion,
        workspaceID: WorkspaceID,
        senderDeviceID: DeviceID,
        message: FileTransferMessage
    ) {
        self.version = version
        self.workspaceID = workspaceID
        self.senderDeviceID = senderDeviceID
        self.message = message
    }

    public func validated(
        workspaceID expectedWorkspaceID: WorkspaceID,
        senderDeviceID expectedSenderDeviceID: DeviceID
    ) throws -> Self {
        guard version == Self.protocolVersion else {
            throw FileTransferProtocolError.unsupportedVersion(version)
        }
        guard workspaceID == expectedWorkspaceID else {
            throw FileTransferProtocolError.workspaceMismatch
        }
        guard senderDeviceID == expectedSenderDeviceID else {
            throw FileTransferProtocolError.peerMismatch
        }
        return self
    }
}
