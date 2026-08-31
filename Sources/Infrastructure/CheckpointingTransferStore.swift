import CryptoKit
import Foundation
import UniSpaceApplication
import UniSpaceDomain

public struct TransferCheckpointConfiguration: Sendable, Equatable {
    public static let `default` = Self()

    public let byteInterval: UInt64
    public let minimumIntervalNanoseconds: UInt64
    public let maximumIntervalNanoseconds: UInt64

    public init(
        byteInterval: UInt64 = 8 * 1_024 * 1_024,
        minimumIntervalNanoseconds: UInt64 = 250_000_000,
        maximumIntervalNanoseconds: UInt64 = 1_000_000_000
    ) {
        precondition(byteInterval > 0)
        precondition(minimumIntervalNanoseconds > 0)
        precondition(maximumIntervalNanoseconds >= minimumIntervalNanoseconds)
        self.byteInterval = byteInterval
        self.minimumIntervalNanoseconds = minimumIntervalNanoseconds
        self.maximumIntervalNanoseconds = maximumIntervalNanoseconds
    }
}

public struct CheckpointingTransferStoreDiagnostics: Sendable, Equatable {
    public let openHandleCount: Int
    public let handleOpenCount: UInt64
    public let checkpointCount: UInt64
    public let metadataWriteCount: UInt64

    public init(
        openHandleCount: Int,
        handleOpenCount: UInt64,
        checkpointCount: UInt64,
        metadataWriteCount: UInt64
    ) {
        self.openHandleCount = openHandleCount
        self.handleOpenCount = handleOpenCount
        self.checkpointCount = checkpointCount
        self.metadataWriteCount = metadataWriteCount
    }
}

/// Incoming staging store optimized for interactive continuity sessions.
///
/// The store keeps a file handle open while an entry is actively receiving and
/// separates bytes written to the OS from bytes made durable for crash-safe
/// resume. The existing wire protocol can continue acknowledging contiguous
/// writes, while `verifiedOffsets` only exposes periodically synchronized and
/// atomically persisted offsets.
public actor CheckpointingTransferStore: TransferStore {
    private struct StoredTransfer: Codable, Sendable {
        var manifest: TransferManifest
        var offsets: [TransferEntryOffset]
        var finalizedEntryIDs: Set<TransferEntryID>
        var createdAt: Date
        var updatedAt: Date
        var completedAt: Date?
    }

    private final class WriteSession: @unchecked Sendable {
        let transferID: TransferID
        let entryID: TransferEntryID
        let handle: FileHandle
        var writtenOffset: UInt64
        var durableOffset: UInt64
        var bytesSinceCheckpoint: UInt64
        var lastCheckpointNanoseconds: UInt64

        init(
            transferID: TransferID,
            entryID: TransferEntryID,
            handle: FileHandle,
            offset: UInt64,
            nowNanoseconds: UInt64
        ) {
            self.transferID = transferID
            self.entryID = entryID
            self.handle = handle
            writtenOffset = offset
            durableOffset = offset
            bytesSinceCheckpoint = 0
            lastCheckpointNanoseconds = nowNanoseconds
        }
    }

    private struct SessionKey: Hashable {
        let transferID: TransferID
        let entryID: TransferEntryID
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let checkpointConfiguration: TransferCheckpointConfiguration
    private let clock: any MonotonicClock

    private var cache: [TransferID: StoredTransfer] = [:]
    private var sessions: [SessionKey: WriteSession] = [:]
    private var handleOpenCount: UInt64 = 0
    private var checkpointCount: UInt64 = 0
    private var metadataWriteCount: UInt64 = 0

    public init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        checkpointConfiguration: TransferCheckpointConfiguration = .default,
        clock: any MonotonicClock = SystemMonotonicClock()
    ) {
        self.fileManager = fileManager
        self.checkpointConfiguration = checkpointConfiguration
        self.clock = clock
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

    deinit {
        sessions.values.forEach { try? $0.handle.close() }
    }

    public func diagnostics() -> CheckpointingTransferStoreDiagnostics {
        CheckpointingTransferStoreDiagnostics(
            openHandleCount: sessions.count,
            handleOpenCount: handleOpenCount,
            checkpointCount: checkpointCount,
            metadataWriteCount: metadataWriteCount
        )
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

        do {
            try fileManager.createDirectory(
                at: partialDirectory(manifest.transferID),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: completedDirectory(manifest.transferID),
                withIntermediateDirectories: true
            )
            let offsets = try manifest.entries.map { entry -> TransferEntryOffset in
                let partial = partialURL(transferID: manifest.transferID, entryID: entry.id)
                guard fileManager.createFile(atPath: partial.path, contents: Data()) else {
                    throw TransferStoreError.invalidStagingState
                }
                return TransferEntryOffset(entryID: entry.id, offset: 0)
            }
            let now = Date()
            try persist(StoredTransfer(
                manifest: manifest,
                offsets: offsets,
                finalizedEntryIDs: [],
                createdAt: now,
                updatedAt: now,
                completedAt: nil
            ))
            excludeFromBackup(transferDirectory(manifest.transferID))
        } catch {
            try? fileManager.removeItem(at: transferDirectory(manifest.transferID))
            cache.removeValue(forKey: manifest.transferID)
            throw error
        }
    }

    public func write(
        _ chunk: TransferChunk,
        limits: FileTransferLimits
    ) async throws -> UInt64 {
        var stored = try load(chunk.transferID)
        try chunk.validated(against: stored.manifest, limits: limits)
        let entry = try entry(chunk.entryID, in: stored.manifest)
        if stored.finalizedEntryIDs.contains(chunk.entryID) { return entry.byteCount }

        let key = SessionKey(transferID: chunk.transferID, entryID: chunk.entryID)
        let session = try openSessionIfNeeded(key: key, stored: stored)
        let (chunkEnd, overflow) = chunk.offset.addingReportingOverflow(UInt64(chunk.data.count))
        guard !overflow else {
            throw TransferStoreError.invalidOffset(
                expected: session.writtenOffset,
                actual: chunk.offset
            )
        }
        if chunk.offset < session.writtenOffset, chunkEnd <= session.writtenOffset {
            return session.writtenOffset
        }
        guard chunk.offset == session.writtenOffset else {
            throw TransferStoreError.invalidOffset(
                expected: session.writtenOffset,
                actual: chunk.offset
            )
        }

        do {
            try session.handle.write(contentsOf: chunk.data)
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw TransferStoreError.insufficientStorage
        }
        session.writtenOffset = chunkEnd
        session.bytesSinceCheckpoint &+= UInt64(chunk.data.count)

        let now = clock.nowNanoseconds()
        if shouldCheckpoint(session, nowNanoseconds: now) {
            stored = try checkpoint(session, stored: stored, nowNanoseconds: now)
            cache[chunk.transferID] = stored
        }
        return session.writtenOffset
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
        let manifestEntry = try entry(entryID, in: stored.manifest)
        let destination = completedURL(transferID: transferID, filename: manifestEntry.filename)

        if stored.finalizedEntryIDs.contains(entryID) {
            guard fileManager.fileExists(atPath: destination.path),
                  try await digest(of: destination) == manifestEntry.sha256 else {
                throw TransferStoreError.hashMismatch(entryID)
            }
            return destination
        }

        let key = SessionKey(transferID: transferID, entryID: entryID)
        if let session = sessions[key] {
            stored = try checkpoint(
                session,
                stored: stored,
                nowNanoseconds: clock.nowNanoseconds(),
                force: true
            )
            closeSession(key)
        }
        let offset = stored.offsets.first(where: { $0.entryID == entryID })?.offset ?? 0
        guard offset == manifestEntry.byteCount else {
            throw TransferStoreError.entryIncomplete(entryID)
        }

        let partial = partialURL(transferID: transferID, entryID: entryID)
        try reconcileFile(partial, toDurableOffset: offset)
        guard try await digest(of: partial) == manifestEntry.sha256 else {
            throw TransferStoreError.hashMismatch(entryID)
        }

        if fileManager.fileExists(atPath: destination.path) {
            guard try await digest(of: destination) == manifestEntry.sha256 else {
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
        return stored.manifest.entries
            .map { completedURL(transferID: transferID, filename: $0.filename) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    public func recoverIncomingTransfers(
        limits: FileTransferLimits
    ) async throws -> [RecoveredIncomingTransfer] {
        await suspendAll()
        try ensureRootExists()
        cache.removeAll(keepingCapacity: true)
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
                var stored = try loadFromDisk(transferID)
                try stored.manifest.validated(limits: limits)
                var reconciled: [TransferEntryOffset] = []
                for manifestEntry in stored.manifest.entries {
                    if stored.finalizedEntryIDs.contains(manifestEntry.id) {
                        let completed = completedURL(
                            transferID: transferID,
                            filename: manifestEntry.filename
                        )
                        guard fileManager.fileExists(atPath: completed.path),
                              try await digest(of: completed) == manifestEntry.sha256 else {
                            throw TransferStoreError.hashMismatch(manifestEntry.id)
                        }
                        reconciled.append(
                            TransferEntryOffset(entryID: manifestEntry.id, offset: manifestEntry.byteCount)
                        )
                        continue
                    }
                    let partial = partialURL(transferID: transferID, entryID: manifestEntry.id)
                    try fileManager.createDirectory(
                        at: partialDirectory(transferID),
                        withIntermediateDirectories: true
                    )
                    if !fileManager.fileExists(atPath: partial.path) {
                        guard fileManager.createFile(atPath: partial.path, contents: Data()) else {
                            throw TransferStoreError.invalidStagingState
                        }
                    }
                    let persisted = stored.offsets.first(where: {
                        $0.entryID == manifestEntry.id
                    })?.offset ?? 0
                    let fileSize = try size(of: partial)
                    let durable = min(min(persisted, fileSize), manifestEntry.byteCount)
                    try reconcileFile(partial, toDurableOffset: durable)
                    reconciled.append(
                        TransferEntryOffset(entryID: manifestEntry.id, offset: durable)
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
                closeSessions(for: transferID)
                cache.removeValue(forKey: transferID)
                try? fileManager.removeItem(at: directory)
            }
        }
        return recovered
    }

    public func suspend(_ transferID: TransferID) async {
        let keys = sessions.keys.filter { $0.transferID == transferID }
        for key in keys {
            guard let session = sessions[key], var stored = try? load(transferID) else {
                closeSession(key)
                continue
            }
            if let checkpointed = try? checkpoint(
                session,
                stored: stored,
                nowNanoseconds: clock.nowNanoseconds(),
                force: true
            ) {
                stored = checkpointed
                cache[transferID] = stored
            }
            closeSession(key)
        }
    }

    public func suspendAll() async {
        let transferIDs = Set(sessions.keys.map(\.transferID))
        for transferID in transferIDs { await suspend(transferID) }
    }

    public func cancel(_ transferID: TransferID) async {
        closeSessions(for: transferID)
        cache.removeValue(forKey: transferID)
        try? fileManager.removeItem(at: transferDirectory(transferID))
    }

    public func remove(_ transferID: TransferID) async {
        await cancel(transferID)
    }

    public func removeExpired(now: Date, limits: FileTransferLimits) async {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let active = Set(sessions.keys.map(\.transferID))
        for directory in directories {
            guard let uuid = UUID(uuidString: directory.lastPathComponent) else { continue }
            let transferID = TransferID(rawValue: uuid)
            guard !active.contains(transferID) else { continue }
            guard let stored = try? load(transferID) else {
                cache.removeValue(forKey: transferID)
                try? fileManager.removeItem(at: directory)
                continue
            }
            let retention = stored.completedAt == nil
                ? limits.partialRetentionSeconds
                : limits.completedRetentionSeconds
            let reference = stored.completedAt ?? stored.updatedAt
            if now.timeIntervalSince(reference) > retention {
                cache.removeValue(forKey: transferID)
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    private func openSessionIfNeeded(
        key: SessionKey,
        stored: StoredTransfer
    ) throws -> WriteSession {
        if let session = sessions[key] { return session }
        let durableOffset = stored.offsets.first(where: { $0.entryID == key.entryID })?.offset ?? 0
        let url = partialURL(transferID: key.transferID, entryID: key.entryID)
        try reconcileFile(url, toDurableOffset: durableOffset)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: durableOffset)
        let session = WriteSession(
            transferID: key.transferID,
            entryID: key.entryID,
            handle: handle,
            offset: durableOffset,
            nowNanoseconds: clock.nowNanoseconds()
        )
        sessions[key] = session
        handleOpenCount &+= 1
        return session
    }

    private func shouldCheckpoint(
        _ session: WriteSession,
        nowNanoseconds: UInt64
    ) -> Bool {
        let elapsed = nowNanoseconds >= session.lastCheckpointNanoseconds
            ? nowNanoseconds - session.lastCheckpointNanoseconds
            : UInt64.max
        return (session.bytesSinceCheckpoint >= checkpointConfiguration.byteInterval
                && elapsed >= checkpointConfiguration.minimumIntervalNanoseconds)
            || elapsed >= checkpointConfiguration.maximumIntervalNanoseconds
    }

    @discardableResult
    private func checkpoint(
        _ session: WriteSession,
        stored input: StoredTransfer,
        nowNanoseconds: UInt64,
        force: Bool = false
    ) throws -> StoredTransfer {
        guard force || session.writtenOffset != session.durableOffset else { return input }
        if session.writtenOffset == session.durableOffset { return input }
        try session.handle.synchronize()
        var stored = input
        let index = try offsetIndex(session.entryID, in: stored)
        stored.offsets[index] = TransferEntryOffset(
            entryID: session.entryID,
            offset: session.writtenOffset
        )
        stored.updatedAt = Date()
        try persist(stored)
        session.durableOffset = session.writtenOffset
        session.bytesSinceCheckpoint = 0
        session.lastCheckpointNanoseconds = nowNanoseconds
        checkpointCount &+= 1
        return stored
    }

    private func closeSessions(for transferID: TransferID) {
        let keys = sessions.keys.filter { $0.transferID == transferID }
        for key in keys { closeSession(key) }
    }

    private func closeSession(_ key: SessionKey) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        try? session.handle.close()
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
        if let stored = cache[transferID] { return stored }
        let stored = try loadFromDisk(transferID)
        cache[transferID] = stored
        return stored
    }

    private func loadFromDisk(_ transferID: TransferID) throws -> StoredTransfer {
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
        cache[stored.manifest.transferID] = stored
        metadataWriteCount &+= 1
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
        guard current != offset else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: offset)
        try handle.synchronize()
    }

    private func size(of url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
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
