import Foundation

public struct ClipboardStreamLimits: Sendable, Equatable {
    public let maximumFiles: Int
    public let maximumReadBytes: Int
    public let maximumLeases: Int
    public let maximumFileBytes: UInt64
    public let leaseLifetimeNanoseconds: UInt64
    public static let `default` = Self()
    public init(maximumFiles: Int = 1_000, maximumReadBytes: Int = 256 * 1_024,
                maximumLeases: Int = 16, maximumFileBytes: UInt64 = 1 << 40,
                leaseLifetimeNanoseconds: UInt64 = 300_000_000_000) {
        self.maximumFiles = maximumFiles; self.maximumReadBytes = maximumReadBytes
        self.maximumLeases = maximumLeases; self.maximumFileBytes = maximumFileBytes
        self.leaseLifetimeNanoseconds = leaseLifetimeNanoseconds
    }
}

public enum ClipboardStreamFailure: String, Codable, Error, Sendable {
    case unavailable, changed, expired, unsupported, invalidRequest, cancelled, ioFailure, integrityFailure, busy
}

public struct ClipboardStreamFile: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let size: UInt64
    public let version: String
    public let contentType: String
    public init(id: UUID = UUID(), name: String, size: UInt64, version: String, contentType: String = "public.data") {
        self.id = id; self.name = name; self.size = size; self.version = version; self.contentType = contentType
    }
    public func validate(limits: ClipboardStreamLimits = .default) throws {
        try TransferFilename.validate(name)
        guard size <= limits.maximumFileBytes, !version.isEmpty, version.utf8.count <= 128,
              !contentType.isEmpty, contentType.utf8.count <= 255 else { throw ClipboardStreamFailure.invalidRequest }
    }
}

public struct ClipboardStreamSelection: Codable, Equatable, Sendable, Identifiable {
    public let epoch: UUID
    public let id: UUID
    public let generation: UInt64
    public let files: [ClipboardStreamFile]
    public init(epoch: UUID, id: UUID = UUID(), generation: UInt64, files: [ClipboardStreamFile]) {
        self.epoch = epoch; self.id = id; self.generation = generation; self.files = files
    }
    public func validate(limits: ClipboardStreamLimits = .default) throws {
        guard generation > 0, !files.isEmpty, files.count <= limits.maximumFiles,
              Set(files.map(\.id)).count == files.count else { throw ClipboardStreamFailure.invalidRequest }
        var names = Set<String>()
        var total: UInt64 = 0
        for file in files {
            try file.validate(limits: limits)
            let (next, overflow) = total.addingReportingOverflow(file.size)
            guard !overflow, next <= limits.maximumFileBytes else { throw ClipboardStreamFailure.invalidRequest }
            total = next
            guard names.insert(file.name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))).inserted else { throw ClipboardStreamFailure.invalidRequest }
        }
    }
}

public struct ClipboardStreamOpen: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let selectionID: UUID
    public let fileID: UUID
    public let version: String
    public init(requestID: UUID = UUID(), selectionID: UUID, fileID: UUID, version: String) {
        self.requestID = requestID; self.selectionID = selectionID; self.fileID = fileID; self.version = version
    }
}

public struct ClipboardStreamLease: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let selectionID: UUID
    public let fileID: UUID
    public let leaseID: UUID
    public let size: UInt64
    public let maximumReadBytes: UInt32
    public init(requestID: UUID, selectionID: UUID, fileID: UUID, leaseID: UUID = UUID(), size: UInt64, maximumReadBytes: UInt32) {
        self.requestID = requestID; self.selectionID = selectionID; self.fileID = fileID
        self.leaseID = leaseID; self.size = size; self.maximumReadBytes = maximumReadBytes
    }
}

public struct ClipboardStreamRead: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let leaseID: UUID
    public let fileID: UUID
    public let offset: UInt64
    public let length: UInt32
    public init(requestID: UUID = UUID(), leaseID: UUID, fileID: UUID, offset: UInt64, length: UInt32) {
        self.requestID = requestID; self.leaseID = leaseID; self.fileID = fileID; self.offset = offset; self.length = length
    }
}

public struct ClipboardStreamRange: Equatable, Sendable, Codable {
    public let requestID: UUID
    public let leaseID: UUID
    public let fileID: UUID
    public let offset: UInt64
    public let data: Data
    public init(requestID: UUID, leaseID: UUID, fileID: UUID, offset: UInt64, data: Data) {
        self.requestID = requestID; self.leaseID = leaseID; self.fileID = fileID; self.offset = offset; self.data = data
    }
}

public struct ClipboardStreamFinish: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let leaseID: UUID
    public let digest: Data
    public init(requestID: UUID = UUID(), leaseID: UUID, digest: Data) {
        self.requestID = requestID; self.leaseID = leaseID; self.digest = digest
    }
}

public struct ClipboardStreamReference: Codable, Equatable, Sendable {
    public let id: UUID
    public init(_ id: UUID) { self.id = id }
}
public struct ClipboardStreamError: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let failure: ClipboardStreamFailure
    public init(requestID: UUID, failure: ClipboardStreamFailure) { self.requestID = requestID; self.failure = failure }
}
public enum ClipboardStreamMessage: Codable, Equatable, Sendable {
    case announce(ClipboardStreamSelection)
    case withdraw(ClipboardStreamReference)
    case open(ClipboardStreamOpen)
    case opened(ClipboardStreamLease)
    case read(ClipboardStreamRead)
    case range(ClipboardStreamRange)
    case finish(ClipboardStreamFinish)
    case finished(ClipboardStreamFinish)
    case close(ClipboardStreamReference)
    case error(ClipboardStreamError)
}
