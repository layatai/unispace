import Foundation
import UniSpaceApplication
import UniSpaceDomain

/// Wraps `SystemFileSourceProvider` and restores its persisted source mappings
/// with sub-second-tolerant metadata checks after an application relaunch.
public actor PersistentSystemFileSourceProvider: FileSourceProvider {
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

    private struct RecoveredEntry: Sendable {
        let url: URL
        let byteCount: UInt64
        let modificationDate: Date?
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let base: SystemFileSourceProvider
    private var recoveredEntries: [TransferID: [TransferEntryID: RecoveredEntry]] = [:]

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.rootURL = applicationSupport
                .appendingPathComponent("UniSpace", isDirectory: true)
                .appendingPathComponent("Transfers", isDirectory: true)
                .appendingPathComponent("Outgoing", isDirectory: true)
        }
        base = SystemFileSourceProvider(rootURL: self.rootURL, fileManager: FileManager())
    }

    public func prepare(
        urls: [URL],
        transferID: TransferID,
        workspaceID: WorkspaceID,
        sourceDeviceID: DeviceID,
        destinationDeviceID: DeviceID,
        limits: FileTransferLimits
    ) async throws -> PreparedOutgoingTransfer {
        recoveredEntries.removeValue(forKey: transferID)
        return try await base.prepare(
            urls: urls,
            transferID: transferID,
            workspaceID: workspaceID,
            sourceDeviceID: sourceDeviceID,
            destinationDeviceID: destinationDeviceID,
            limits: limits
        )
    }

    public func readChunk(
        transferID: TransferID,
        entryID: TransferEntryID,
        offset: UInt64,
        maximumLength: Int
    ) async throws -> Data {
        guard let recovered = recoveredEntries[transferID]?[entryID] else {
            return try await base.readChunk(
                transferID: transferID,
                entryID: entryID,
                offset: offset,
                maximumLength: maximumLength
            )
        }
        guard maximumLength > 0,
              maximumLength <= FileTransferLimits.default.maximumChunkSize,
              offset <= recovered.byteCount else {
            throw FileSourceError.invalidReadRange
        }
        try validate(recovered)
        let access = recovered.url.startAccessingSecurityScopedResource()
        defer { if access { recovered.url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: recovered.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let remaining = recovered.byteCount - offset
        let requested = min(maximumLength, Int(clamping: remaining))
        let data = try handle.read(upToCount: requested) ?? Data()
        guard data.count <= requested else { throw FileSourceError.invalidReadRange }
        try validate(recovered)
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

        var recoveredTransfers: [PreparedOutgoingTransfer] = []
        for file in files {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let stored = try decoder.decode(
                    StoredSource.self,
                    from: Data(contentsOf: file)
                )
                let manifest = try stored.manifest.validated(limits: limits)
                var entries: [TransferEntryID: RecoveredEntry] = [:]
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
                    let recovered = RecoveredEntry(
                        url: url,
                        byteCount: storedEntry.byteCount,
                        modificationDate: storedEntry.modificationDate
                    )
                    try validate(recovered)
                    entries[storedEntry.entryID] = recovered
                }
                recoveredEntries[manifest.transferID] = entries
                recoveredTransfers.append(PreparedOutgoingTransfer(manifest: manifest))
            } catch {
                try? fileManager.removeItem(at: file)
            }
        }
        return recoveredTransfers
    }

    public func removeOutgoingTransfer(_ transferID: TransferID) async {
        recoveredEntries.removeValue(forKey: transferID)
        await base.removeOutgoingTransfer(transferID)
    }

    private func validate(_ entry: RecoveredEntry) throws {
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

    private func datesEqual(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?):
            // JSONEncoder's ISO-8601 strategy may omit fractional seconds.
            abs(lhs.timeIntervalSince(rhs)) < 1.1
        default: false
        }
    }
}
