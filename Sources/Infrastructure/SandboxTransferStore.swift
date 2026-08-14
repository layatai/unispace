import CryptoKit
import Foundation
import UniSpaceApplication
import UniSpaceDomain

public enum TransferStoreError: Error, LocalizedError, Equatable, Sendable {
    case transferNotFound(TransferID)
    case manifestMismatch
    case invalidOffset(expected: UInt64, actual: UInt64)
    case insufficientStorage
    case hashMismatch(TransferEntryID)
    case entryIncomplete(TransferEntryID)
    case transferIncomplete
    case invalidStagingState

    public var errorDescription: String? {
        switch self {
        case .transferNotFound:
            "The staged transfer no longer exists."
        case .manifestMismatch:
            "The staged transfer metadata does not match the incoming offer."
        case .invalidOffset:
            "The incoming data does not continue from the durable file offset."
        case .insufficientStorage:
            "This Mac does not have enough available storage for the transfer."
        case .hashMismatch:
            "A received file failed its integrity check."
        case .entryIncomplete, .transferIncomplete:
            "The transfer has not received all expected data."
        case .invalidStagingState:
            "The staged transfer metadata is invalid."
        }
    }
}

public actor SandboxTransferStore: TransferStore {
    private struct StoredTransfer: Codable, Sendable {
        var manifest: TransferManifest
        var offsets: [TransferEntryOffset]
        var finalizedEntryIDs: Set<TransferEntryID>
        var createdAt: Date
        var updatedAt: Date
        var completedAt: Date?
    }

    private let rootURL: URL
    private let fileManager: FileManager

    public init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.rootURL = base
                .appendingPathComponent("UniSpace", isDirectory: true)
                .appendingPathComponent("Transfers", isDirectory: true)
                .appendingPathComponent("Incoming", isDirectory: true)
        }
    }

    public func prepareIncoming(
        manifest: TransferManifest,
        limits: FileTransferLimits
    ) async throws {
        let manifest = try manifest.validated(limits: limits)
        try ensureRootExists()
        try ensureAvailableCapacity(for: manifest.totalByteCount)

        let metadata = metadataURL(manifest.transferID)
        if fileManager.fileExists(atPath: metadata.path) {
            let existing = try load(manifest.transferID)
            guard existing.manifest == manifest else { throw TransferStoreError.manifestMismatch }
            return
        }

        try fileManager.createDirectory(
            at: partialDirectory(manifest.transferID),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: completedDirectory(manifest.transferID),
            withIntermediateDirectories: true
        )
        var offsets: [TransferEntryOffset] = []
        for entry in manifest.entries {
            let partial = partialURL(transferID: manifest.transferID, entryID: entry.id)
            guard fileManager.createFile(atPath: partial.path, contents: Data()) else {
                throw TransferStoreError.invalidStagingState
            }
            offsets.append(TransferEntryOffset(entryID: entry.id, offset: 0))
        }
        try persist(StoredTransfer(
            manifest: manifest,
            offsets: offsets,
            finalizedEntryIDs: [],
            createdAt: Date(),
            updatedAt: Date(),
            completedAt: nil
        ))
        excludeFromBackup(transferDirectory(manifest.transferID))
    }

    public func write(
        _ chunk: TransferChunk,
        limits: FileTransferLimits
    ) async throws -> UInt64 {
        var stored = try load(chunk.transferID)
        try chunk.validated(against: stored.manifest, limits: limits)
        guard !stored.finalizedEntryIDs.contains(chunk.entryID) else {
            return try entry(chunk.entryID, in: stored.manifest).byteCount
        }

        let index = try offsetIndex(chunk.entryID, in: stored)
        let durableOffset = stored.offsets[index].offset
        guard chunk.offset == durableOffset else {
            throw TransferStoreError.invalidOffset(expected: durableOffset, actual: chunk.offset)
        }

        let url = partialURL(transferID: chunk.transferID, entryID: chunk.entryID)
        try reconcileFile(url, toDurableOffset: durableOffset)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: durableOffset)
        do {
            try handle.write(contentsOf: chunk.data)
            try handle.synchronize()
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw TransferStoreError.insufficientStorage
        }

        let nextOffset = durableOffset + UInt64(chunk.data.count)
        stored.offsets[index] = TransferEntryOffset(entryID: chunk.entryID, offset: nextOffset)
        stored.updatedAt = Date()
        try persist(stored)
        return nextOffset
    }

    public func verifiedOffsets(for transferID: TransferID) async throws -> [TransferEntryOffset] {
        let stored = try load(transferID)
        return stored.manifest.entries.map { entry in
            let offset = stored.offsets.first(where: { $0.entryID == entry.id })?.offset ?? 0
            return TransferEntryOffset(entryID: entry.id, offset: min(offset, entry.byteCount))
        }
    }

    public func finalizeEntry(
        transferID: TransferID,
        entryID: TransferEntryID
    ) async throws -> URL {
        var stored = try load(transferID)
        let entry = try entry(entryID, in: stored.manifest)
        let destination = completedURL(transferID: transferID, filename: entry.filename)

        if stored.finalizedEntryIDs.contains(entryID) {
            guard fileManager.fileExists(atPath: destination.path),
                  try digest(of: destination) == entry.sha256 else {
                throw TransferStoreError.hashMismatch(entryID)
            }
            return destination
        }

        let offset = stored.offsets.first(where: { $0.entryID == entryID })?.offset ?? 0
        guard offset == entry.byteCount else {
            throw TransferStoreError.entryIncomplete(entryID)
        }
        let partial = partialURL(transferID: transferID, entryID: entryID)
        try reconcileFile(partial, toDurableOffset: offset)
        guard try digest(of: partial) == entry.sha256 else {
            throw TransferStoreError.hashMismatch(entryID)
        }

        if fileManager.fileExists(atPath: destination.path) {
            guard try digest(of: destination) == entry.sha256 else {
                throw TransferStoreError.hashMismatch(entryID)
            }
            try? fileManager.removeItem(at: partial)
        } else {
            try fileManager.moveItem(at: partial, to: destination)
        }
        stored.finalizedEntryIDs.insert(entryID)
        stored.updatedAt = Date()
        try persist(stored)
        return destination
    }

    public func finalizeTransfer(_ transferID: TransferID) async throws -> [URL] {
        var stored = try load(transferID)
        guard stored.finalizedEntryIDs.count == stored.manifest.entries.count,
              stored.manifest.entries.allSatisfy({ stored.finalizedEntryIDs.contains($0.id) }) else {
            throw TransferStoreError.transferIncomplete
        }
        let urls = stored.manifest.entries.map {
            completedURL(transferID: transferID, filename: $0.filename)
        }
        guard urls.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            throw TransferStoreError.transferIncomplete
        }
        stored.completedAt = stored.completedAt ?? Date()
        stored.updatedAt = Date()
        try persist(stored)
        return urls
    }

    public func completedURLs(for transferID: TransferID) async throws -> [URL] {
        let stored = try load(transferID)
        guard stored.completedAt != nil else { return [] }
        let urls = stored.manifest.entries.map {
            completedURL(transferID: transferID, filename: $0.filename)
        }
        return urls.filter { fileManager.fileExists(atPath: $0.path) }
    }

    public func recoverIncomingTransfers(
        limits: FileTransferLimits
    ) async throws -> [RecoveredIncomingTransfer] {
        try ensureRootExists()
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var recovered: [RecoveredIncomingTransfer] = []
        for directory in directories {
            guard let uuid = UUID(uuidString: directory.lastPathComponent) else { continue }
            let transferID = TransferID(rawValue: uuid)
            do {
                var stored = try load(transferID)
                try stored.manifest.validated(limits: limits)
                var reconciled: [TransferEntryOffset] = []
                for entry in stored.manifest.entries {
                    if stored.finalizedEntryIDs.contains(entry.id) {
                        let completed = completedURL(
                            transferID: transferID,
                            filename: entry.filename
                        )
                        guard fileManager.fileExists(atPath: completed.path),
                              try digest(of: completed) == entry.sha256 else {
                            throw TransferStoreError.hashMismatch(entry.id)
                        }
                        reconciled.append(
                            TransferEntryOffset(entryID: entry.id, offset: entry.byteCount)
                        )
                        continue
                    }
                    let partial = partialURL(transferID: transferID, entryID: entry.id)
                    if !fileManager.fileExists(atPath: partial.path) {
                        guard fileManager.createFile(atPath: partial.path, contents: Data()) else {
                            throw TransferStoreError.invalidStagingState
                        }
                    }
                    let persisted = stored.offsets.first(where: { $0.entryID == entry.id })?.offset ?? 0
                    let fileSize = try size(of: partial)
                    let durable = min(min(persisted, fileSize), entry.byteCount)
                    try reconcileFile(partial, toDurableOffset: durable)
                    reconciled.append(
                        TransferEntryOffset(entryID: entry.id, offset: durable)
                    )
                }
                stored.offsets = reconciled
                stored.updatedAt = Date()
                try persist(stored)
                let completed = stored.completedAt == nil
                    ? []
                    : try await completedURLs(for: transferID)
                recovered.append(RecoveredIncomingTransfer(
                    manifest: stored.manifest,
                    offsets: reconciled,
                    completedURLs: completed
                ))
            } catch {
                try? fileManager.removeItem(at: directory)
            }
        }
        return recovered
    }

    public func cancel(_ transferID: TransferID) async {
        try? fileManager.removeItem(at: transferDirectory(transferID))
    }

    public func remove(_ transferID: TransferID) async {
        try? fileManager.removeItem(at: transferDirectory(transferID))
    }

    public func removeExpired(now: Date, limits: FileTransferLimits) async {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for directory in directories {
            guard let uuid = UUID(uuidString: directory.lastPathComponent) else { continue }
            let transferID = TransferID(rawValue: uuid)
            guard let stored = try? load(transferID) else {
                try? fileManager.removeItem(at: directory)
                continue
            }
            let retention = stored.completedAt == nil
                ? limits.partialRetentionSeconds
                : limits.completedRetentionSeconds
            let reference = stored.completedAt ?? stored.updatedAt
            if now.timeIntervalSince(reference) > retention {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    private func ensureRootExists() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func ensureAvailableCapacity(for bytes: UInt64) throws {
        let attributes = try fileManager.attributesOfFileSystem(forPath: rootURL.path)
        guard let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value else { return }
        let reserve: UInt64 = 64 * 1_024 * 1_024
        let (required, overflow) = bytes.addingReportingOverflow(reserve)
        guard !overflow, free >= required else { throw TransferStoreError.insufficientStorage }
    }

    private func load(_ transferID: TransferID) throws -> StoredTransfer {
        let url = metadataURL(transferID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw TransferStoreError.transferNotFound(transferID)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredTransfer.self, from: Data(contentsOf: url))
    }

    private func persist(_ stored: StoredTransfer) throws {
        try fileManager.createDirectory(
            at: transferDirectory(stored.manifest.transferID),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(stored)
        try data.write(to: metadataURL(stored.manifest.transferID), options: [.atomic])
    }

    private func offsetIndex(_ entryID: TransferEntryID, in stored: StoredTransfer) throws -> Int {
        guard let index = stored.offsets.firstIndex(where: { $0.entryID == entryID }) else {
            throw FileTransferProtocolError.unknownEntry(entryID)
        }
        return index
    }

    private func entry(
        _ entryID: TransferEntryID,
        in manifest: TransferManifest
    ) throws -> TransferManifestEntry {
        guard let entry = manifest.entry(id: entryID) else {
            throw FileTransferProtocolError.unknownEntry(entryID)
        }
        return entry
    }

    private func reconcileFile(_ url: URL, toDurableOffset offset: UInt64) throws {
        let current = try size(of: url)
        if current != offset {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: offset)
            try handle.synchronize()
        }
    }

    private func size(of url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
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

    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    private func transferDirectory(_ transferID: TransferID) -> URL {
        rootURL.appendingPathComponent(transferID.rawValue.uuidString, isDirectory: true)
    }

    private func partialDirectory(_ transferID: TransferID) -> URL {
        transferDirectory(transferID).appendingPathComponent("Partial", isDirectory: true)
    }

    private func completedDirectory(_ transferID: TransferID) -> URL {
        transferDirectory(transferID).appendingPathComponent("Completed", isDirectory: true)
    }

    private func metadataURL(_ transferID: TransferID) -> URL {
        transferDirectory(transferID).appendingPathComponent("transfer.json")
    }

    private func partialURL(transferID: TransferID, entryID: TransferEntryID) -> URL {
        partialDirectory(transferID)
            .appendingPathComponent(entryID.rawValue.uuidString)
            .appendingPathExtension("partial")
    }

    private func completedURL(transferID: TransferID, filename: String) -> URL {
        completedDirectory(transferID).appendingPathComponent(filename, isDirectory: false)
    }
}
