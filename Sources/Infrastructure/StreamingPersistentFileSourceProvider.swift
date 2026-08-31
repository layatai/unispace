import CryptoKit
import Foundation
import UniformTypeIdentifiers
import UniSpaceApplication
import UniSpaceDomain

public struct StreamingFileSourceConfiguration: Sendable, Equatable {
    public static let `default` = Self()

    public let validationByteInterval: UInt64
    public let validationTimeIntervalNanoseconds: UInt64

    public init(
        validationByteInterval: UInt64 = 16 * 1_024 * 1_024,
        validationTimeIntervalNanoseconds: UInt64 = 1_000_000_000
    ) {
        precondition(validationByteInterval > 0)
        precondition(validationTimeIntervalNanoseconds > 0)
        self.validationByteInterval = validationByteInterval
        self.validationTimeIntervalNanoseconds = validationTimeIntervalNanoseconds
    }
}

public struct StreamingFileSourceDiagnostics: Sendable, Equatable {
    public let openHandleCount: Int
    public let handleOpenCount: UInt64
    public let validationCount: UInt64

    public init(openHandleCount: Int, handleOpenCount: UInt64, validationCount: UInt64) {
        self.openHandleCount = openHandleCount
        self.handleOpenCount = handleOpenCount
        self.validationCount = validationCount
    }
}

/// Restart-safe outgoing source provider that keeps each active source file open
/// for sequential streaming rather than reopening and revalidating it for every
/// transfer chunk.
public actor StreamingPersistentFileSourceProvider: FileSourceProvider {
    private struct StoredEntry: Codable, Sendable {
        let entryID: TransferEntryID
        let bookmark: Data?
        let fallbackPath: String
        let byteCount: UInt64
        let modificationDate: Date?
        let sha256: Data
    }

    private struct StoredSource: Codable, Sendable {
        let manifest: TransferManifest
        let entries: [StoredEntry]
    }

    private struct LiveEntry: Sendable {
        let url: URL
        let byteCount: UInt64
        let modificationDate: Date?
        let sha256: Data
    }

    private struct LiveSource: Sendable {
        let manifest: TransferManifest
        let entries: [TransferEntryID: LiveEntry]
    }

    private final class ReadSession: @unchecked Sendable {
        let transferID: TransferID
        let entryID: TransferEntryID
        let entry: LiveEntry
        let handle: FileHandle
        let hasSecurityScope: Bool
        var expectedOffset: UInt64
        var bytesSinceValidation: UInt64
        var lastValidationNanoseconds: UInt64

        init(
            transferID: TransferID,
            entryID: TransferEntryID,
            entry: LiveEntry,
            handle: FileHandle,
            hasSecurityScope: Bool,
            offset: UInt64,
            nowNanoseconds: UInt64
        ) {
            self.transferID = transferID
            self.entryID = entryID
            self.entry = entry
            self.handle = handle
            self.hasSecurityScope = hasSecurityScope
            expectedOffset = offset
            bytesSinceValidation = 0
            lastValidationNanoseconds = nowNanoseconds
        }
    }

    private struct SessionKey: Hashable {
        let transferID: TransferID
        let entryID: TransferEntryID
    }

    private struct PreparedEntry {
        let manifestEntry: TransferManifestEntry
        let storedEntry: StoredEntry
        let liveEntry: LiveEntry
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let configuration: StreamingFileSourceConfiguration
    private let clock: any MonotonicClock
    private var sources: [TransferID: LiveSource] = [:]
    private var sessions: [SessionKey: ReadSession] = [:]
    private var handleOpenCount: UInt64 = 0
    private var validationCount: UInt64 = 0

    public init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        configuration: StreamingFileSourceConfiguration = .default,
        clock: any MonotonicClock = SystemMonotonicClock()
    ) {
        self.fileManager = fileManager
        self.configuration = configuration
        self.clock = clock
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.rootURL = base
                .appendingPathComponent("UniSpace", isDirectory: true)
                .appendingPathComponent("Transfers", isDirectory: true)
                .appendingPathComponent("Outgoing", isDirectory: true)
        }
    }

    deinit {
        sessions.values.forEach { session in
            try? session.handle.close()
            if session.hasSecurityScope { session.entry.url.stopAccessingSecurityScopedResource() }
        }
    }

    public func diagnostics() -> StreamingFileSourceDiagnostics {
        StreamingFileSourceDiagnostics(
            openHandleCount: sessions.count,
            handleOpenCount: handleOpenCount,
            validationCount: validationCount
        )
    }

    public func prepare(
        urls: [URL],
        transferID: TransferID,
        workspaceID: WorkspaceID,
        sourceDeviceID: DeviceID,
        destinationDeviceID: DeviceID,
        limits: FileTransferLimits
    ) async throws -> PreparedOutgoingTransfer {
        guard !urls.isEmpty else { throw FileTransferProtocolError.emptyManifest }
        guard urls.count <= limits.maximumManifestEntries else {
            throw FileTransferProtocolError.tooManyEntries(urls.count)
        }
        await suspend(transferID)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var usedNames = Set<String>()
        var manifestEntries: [TransferManifestEntry] = []
        var storedEntries: [StoredEntry] = []
        var liveEntries: [TransferEntryID: LiveEntry] = [:]
        do {
            for sourceURL in urls {
                let requestedName = sourceURL.standardizedFileURL.lastPathComponent
                    .precomposedStringWithCanonicalMapping
                let filename = uniqueFilename(
                    requestedName,
                    usedNames: &usedNames,
                    maximumBytes: limits.maximumFilenameBytes
                )
                let prepared = try await prepareEntry(
                    sourceURL,
                    filename: filename,
                    limits: limits
                )
                manifestEntries.append(prepared.manifestEntry)
                storedEntries.append(prepared.storedEntry)
                liveEntries[prepared.manifestEntry.id] = prepared.liveEntry
            }

            let manifest = try TransferManifest(
                transferID: transferID,
                workspaceID: workspaceID,
                sourceDeviceID: sourceDeviceID,
                destinationDeviceID: destinationDeviceID,
                entries: manifestEntries
            ).validated(limits: limits)
            let source = StoredSource(manifest: manifest, entries: storedEntries)
            try persist(source)
            sources[transferID] = LiveSource(manifest: manifest, entries: liveEntries)
            return PreparedOutgoingTransfer(manifest: manifest)
        } catch {
            sources.removeValue(forKey: transferID)
            try? fileManager.removeItem(at: metadataURL(transferID))
            throw error
        }
    }

    public func readChunk(
        transferID: TransferID,
        entryID: TransferEntryID,
        offset: UInt64,
        maximumLength: Int
    ) async throws -> Data {
        guard maximumLength > 0,
              maximumLength <= FileTransferLimits.default.maximumChunkSize else {
            throw FileSourceError.invalidReadRange
        }
        guard let source = sources[transferID], let entry = source.entries[entryID] else {
            throw FileSourceError.sourceNotFound
        }
        guard offset <= entry.byteCount else { throw FileSourceError.invalidReadRange }

        let key = SessionKey(transferID: transferID, entryID: entryID)
        var session = try openSessionIfNeeded(key: key, entry: entry, offset: offset)
        if session.expectedOffset != offset {
            closeSession(key)
            session = try openSessionIfNeeded(key: key, entry: entry, offset: offset)
        }

        let remaining = entry.byteCount - offset
        let requested = min(maximumLength, Int(clamping: remaining))
        let data = try session.handle.read(upToCount: requested) ?? Data()
        guard data.count <= requested else { throw FileSourceError.invalidReadRange }
        session.expectedOffset &+= UInt64(data.count)
        session.bytesSinceValidation &+= UInt64(data.count)

        let now = clock.nowNanoseconds()
        let elapsed = now >= session.lastValidationNanoseconds
            ? now - session.lastValidationNanoseconds
            : UInt64.max
        if session.bytesSinceValidation >= configuration.validationByteInterval
            || elapsed >= configuration.validationTimeIntervalNanoseconds
            || session.expectedOffset == entry.byteCount {
            do {
                try validate(entry, tolerantDateComparison: false)
                validationCount &+= 1
                session.bytesSinceValidation = 0
                session.lastValidationNanoseconds = now
            } catch {
                closeSession(key)
                throw error
            }
        }
        return data
    }

    public func recoverOutgoingTransfers(
        limits: FileTransferLimits
    ) async throws -> [PreparedOutgoingTransfer] {
        await suspendAll()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        sources.removeAll(keepingCapacity: true)
        let files = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        var recovered: [PreparedOutgoingTransfer] = []
        for file in files {
            do {
                let stored = try decode(StoredSource.self, from: Data(contentsOf: file))
                let manifest = try stored.manifest.validated(limits: limits)
                var entries: [TransferEntryID: LiveEntry] = [:]
                for storedEntry in stored.entries {
                    var stale = false
                    let url: URL
                    if let bookmark = storedEntry.bookmark {
                        url = try URL(
                            resolvingBookmarkData: bookmark,
                            options: [.withSecurityScope],
                            relativeTo: nil,
                            bookmarkDataIsStale: &stale
                        )
                        guard !stale else { throw FileSourceError.sourceChanged }
                    } else {
                        url = URL(fileURLWithPath: storedEntry.fallbackPath)
                    }
                    let live = LiveEntry(
                        url: url,
                        byteCount: storedEntry.byteCount,
                        modificationDate: storedEntry.modificationDate,
                        sha256: storedEntry.sha256
                    )
                    try validate(live, tolerantDateComparison: true)
                    entries[storedEntry.entryID] = live
                }
                guard entries.count == manifest.entries.count else {
                    throw FileSourceError.sourceChanged
                }
                sources[manifest.transferID] = LiveSource(manifest: manifest, entries: entries)
                recovered.append(PreparedOutgoingTransfer(manifest: manifest))
            } catch {
                try? fileManager.removeItem(at: file)
            }
        }
        return recovered
    }

    public func suspend(_ transferID: TransferID) async {
        let keys = sessions.keys.filter { $0.transferID == transferID }
        for key in keys { closeSession(key) }
    }

    public func suspendAll() async {
        let keys = Array(sessions.keys)
        for key in keys { closeSession(key) }
    }

    public func removeOutgoingTransfer(_ transferID: TransferID) async {
        await suspend(transferID)
        sources.removeValue(forKey: transferID)
        try? fileManager.removeItem(at: metadataURL(transferID))
    }

    private func prepareEntry(
        _ sourceURL: URL,
        filename: String,
        limits: FileTransferLimits
    ) async throws -> PreparedEntry {
        let url = sourceURL.standardizedFileURL
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isReadableKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .contentTypeKey,
        ])
        guard values.isSymbolicLink != true else { throw FileSourceError.symbolicLink }
        guard values.isRegularFile == true else { throw FileSourceError.notRegularFile }
        guard values.isReadable != false,
              let rawSize = values.fileSize,
              rawSize >= 0 else {
            throw FileSourceError.unreadable
        }
        let byteCount = UInt64(rawSize)
        guard byteCount <= limits.maximumTransferBytes else {
            throw FileTransferProtocolError.invalidFileSize(TransferEntryID())
        }

        let entryID = TransferEntryID()
        let digest = try await digest(of: url)
        let manifestEntry = try TransferManifestEntry(
            id: entryID,
            filename: filename,
            contentTypeIdentifier: values.contentType?.identifier,
            byteCount: byteCount,
            sha256: digest,
            modificationDate: values.contentModificationDate
        ).validated(limits: limits)
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return PreparedEntry(
            manifestEntry: manifestEntry,
            storedEntry: StoredEntry(
                entryID: entryID,
                bookmark: bookmark,
                fallbackPath: url.path,
                byteCount: byteCount,
                modificationDate: values.contentModificationDate,
                sha256: digest
            ),
            liveEntry: LiveEntry(
                url: url,
                byteCount: byteCount,
                modificationDate: values.contentModificationDate,
                sha256: digest
            )
        )
    }

    private func openSessionIfNeeded(
        key: SessionKey,
        entry: LiveEntry,
        offset: UInt64
    ) throws -> ReadSession {
        if let session = sessions[key] { return session }
        try validate(entry, tolerantDateComparison: false)
        validationCount &+= 1
        let access = entry.url.startAccessingSecurityScopedResource()
        do {
            let handle = try FileHandle(forReadingFrom: entry.url)
            try handle.seek(toOffset: offset)
            let session = ReadSession(
                transferID: key.transferID,
                entryID: key.entryID,
                entry: entry,
                handle: handle,
                hasSecurityScope: access,
                offset: offset,
                nowNanoseconds: clock.nowNanoseconds()
            )
            sessions[key] = session
            handleOpenCount &+= 1
            return session
        } catch {
            if access { entry.url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private func closeSession(_ key: SessionKey) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        try? session.handle.close()
        if session.hasSecurityScope {
            session.entry.url.stopAccessingSecurityScopedResource()
        }
    }

    private func validate(_ entry: LiveEntry, tolerantDateComparison: Bool) throws {
        guard fileManager.fileExists(atPath: entry.url.path) else {
            throw FileSourceError.sourceNotFound
        }
        let attributes = try fileManager.attributesOfItem(atPath: entry.url.path)
        let fileType = attributes[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink { throw FileSourceError.symbolicLink }
        guard fileType == .typeRegular else { throw FileSourceError.notRegularFile }
        let tolerance = tolerantDateComparison ? 1.1 : 0.01
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0,
              size.uint64Value == entry.byteCount,
              datesEqual(
                attributes[.modificationDate] as? Date,
                entry.modificationDate,
                tolerance: tolerance
              ) else {
            throw FileSourceError.sourceChanged
        }
    }

    private func digest(of url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            return Data(hasher.finalize())
        }.value
    }

    private func persist(_ source: StoredSource) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(source).write(to: metadataURL(source.manifest.transferID), options: [.atomic])
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func metadataURL(_ transferID: TransferID) -> URL {
        rootURL
            .appendingPathComponent(transferID.rawValue.uuidString)
            .appendingPathExtension("json")
    }

    private func datesEqual(_ lhs: Date?, _ rhs: Date?, tolerance: TimeInterval) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): abs(lhs.timeIntervalSince(rhs)) < tolerance
        default: false
        }
    }

    private func uniqueFilename(
        _ requested: String,
        usedNames: inout Set<String>,
        maximumBytes: Int
    ) -> String {
        let fallback = requested.isEmpty ? "File" : requested
        let fileExtension = (fallback as NSString).pathExtension
        let base = (fallback as NSString).deletingPathExtension
        var candidate = truncated(fallback, maximumBytes: maximumBytes)
        var index = 2
        while !usedNames.insert(folded(candidate)).inserted {
            let suffix = " \(index)"
            let suffixAndExtension = fileExtension.isEmpty
                ? suffix
                : suffix + "." + fileExtension
            let available = max(maximumBytes - suffixAndExtension.utf8.count, 1)
            candidate = truncated(base, maximumBytes: available) + suffixAndExtension
            index += 1
        }
        return candidate
    }

    private func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func truncated(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        for character in value {
            let next = result + String(character)
            if next.utf8.count > maximumBytes { break }
            result = next
        }
        return result.isEmpty ? "File" : result
    }
}
