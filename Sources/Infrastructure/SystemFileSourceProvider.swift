import CryptoKit
import Foundation
import UniformTypeIdentifiers
import UniSpaceApplication
import UniSpaceDomain

public enum FileSourceError: Error, LocalizedError, Equatable, Sendable {
    case unreadable
    case notRegularFile
    case symbolicLink
    case sourceChanged
    case sourceNotFound
    case invalidReadRange

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            "A selected file cannot be read."
        case .notRegularFile:
            "Only regular files can be transferred."
        case .symbolicLink:
            "Symbolic links cannot be transferred."
        case .sourceChanged:
            "A source file changed during transfer."
        case .sourceNotFound:
            "A source file is no longer available."
        case .invalidReadRange:
            "The requested file range is invalid."
        }
    }
}

public actor SystemFileSourceProvider: FileSourceProvider {
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

    private let rootURL: URL
    private let fileManager: FileManager
    private var sources: [TransferID: LiveSource] = [:]

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
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
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var usedNames = Set<String>()
        var manifestEntries: [TransferManifestEntry] = []
        var storedEntries: [StoredEntry] = []
        var liveEntries: [TransferEntryID: LiveEntry] = [:]

        for sourceURL in urls {
            let url = sourceURL.standardizedFileURL
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isReadableKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .contentTypeKey
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
            let filename = uniqueFilename(
                url.lastPathComponent.precomposedStringWithCanonicalMapping,
                usedNames: &usedNames,
                maximumBytes: limits.maximumFilenameBytes
            )
            let digest = try digest(of: url)
            let entry = try TransferManifestEntry(
                id: entryID,
                filename: filename,
                contentTypeIdentifier: values.contentType?.identifier,
                byteCount: byteCount,
                sha256: digest,
                modificationDate: values.contentModificationDate
            ).validated(limits: limits)
            manifestEntries.append(entry)

            let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            storedEntries.append(StoredEntry(
                entryID: entryID,
                bookmark: bookmark,
                fallbackPath: url.path,
                byteCount: byteCount,
                modificationDate: values.contentModificationDate,
                sha256: digest
            ))
            liveEntries[entryID] = LiveEntry(
                url: url,
                byteCount: byteCount,
                modificationDate: values.contentModificationDate,
                sha256: digest
            )
        }

        let manifest = try TransferManifest(
            transferID: transferID,
            workspaceID: workspaceID,
            sourceDeviceID: sourceDeviceID,
            destinationDeviceID: destinationDeviceID,
            entries: manifestEntries
        ).validated(limits: limits)
        sources[transferID] = LiveSource(manifest: manifest, entries: liveEntries)
        try persist(StoredSource(manifest: manifest, entries: storedEntries))
        return PreparedOutgoingTransfer(manifest: manifest)
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
        try validate(entry)

        let access = entry.url.startAccessingSecurityScopedResource()
        defer { if access { entry.url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: entry.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let remaining = entry.byteCount - offset
        let requested = min(maximumLength, Int(clamping: remaining))
        let data = try handle.read(upToCount: requested) ?? Data()
        guard data.count <= requested else { throw FileSourceError.invalidReadRange }
        try validate(entry)
        return data
    }

    public func recoverOutgoingTransfers(
        limits: FileTransferLimits
    ) async throws -> [PreparedOutgoingTransfer] {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
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
                    try validate(live)
                    entries[storedEntry.entryID] = live
                }
                sources[manifest.transferID] = LiveSource(manifest: manifest, entries: entries)
                recovered.append(PreparedOutgoingTransfer(manifest: manifest))
            } catch {
                try? fileManager.removeItem(at: file)
            }
        }
        return recovered
    }

    public func removeOutgoingTransfer(_ transferID: TransferID) async {
        sources.removeValue(forKey: transferID)
        try? fileManager.removeItem(at: metadataURL(transferID))
    }

    private func validate(_ entry: LiveEntry) throws {
        guard fileManager.fileExists(atPath: entry.url.path) else {
            throw FileSourceError.sourceNotFound
        }
        let access = entry.url.startAccessingSecurityScopedResource()
        defer { if access { entry.url.stopAccessingSecurityScopedResource() } }
        let attributes = try fileManager.attributesOfItem(atPath: entry.url.path)
        let fileType = attributes[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink { throw FileSourceError.symbolicLink }
        guard fileType == .typeRegular else {
            throw FileSourceError.notRegularFile
        }
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0,
              size.uint64Value == entry.byteCount,
              datesEqual(attributes[.modificationDate] as? Date, entry.modificationDate) else {
            throw FileSourceError.sourceChanged
        }
    }

    private func digest(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
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

    private func datesEqual(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): abs(lhs.timeIntervalSince(rhs)) < 0.001
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
