import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers
import UniSpaceApplication
import UniSpaceDomain

/// Local paths and security-scoped references stay inside this source. Describe
/// uses stat only; content handles and SHA-256 scans start after a read request.
public actor LocalClipboardSelectionSource: ClipboardSelectionSource {
    private struct Reference {
        let url: URL
        let file: ClipboardStreamFile
        let scoped: Bool
    }
    private var selections: [UUID: [UUID: Reference]] = [:]
    public init() {}
    public func describe(urls: [URL], epoch: UUID, generation: UInt64) async throws -> ClipboardStreamSelection {
        guard !urls.isEmpty, urls.count <= ClipboardStreamLimits.default.maximumFiles else { throw ClipboardStreamFailure.invalidRequest }
        var references: [UUID: Reference] = [:]
        var names = Set<String>()
        var files: [ClipboardStreamFile] = []
        do {
            for candidate in urls {
                guard candidate.isFileURL else { throw ClipboardStreamFailure.invalidRequest }
                let url = candidate.standardizedFileURL
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    let stamp = try FileStamp.path(url)
                    let name = uniqueName(url.lastPathComponent.precomposedStringWithCanonicalMapping, used: &names)
                    let file = ClipboardStreamFile(name: name, size: stamp.size, version: stamp.version,
                        contentType: UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data")
                    try file.validate()
                    files.append(file)
                    references[file.id] = Reference(url: url, file: file, scoped: scoped)
                } catch {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    throw error
                }
            }
            let selection = ClipboardStreamSelection(epoch: epoch, generation: generation, files: files)
            try selection.validate()
            selections[selection.id] = references
            return selection
        } catch {
            for reference in references.values where reference.scoped { reference.url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
    public func open(selectionID: UUID, file: ClipboardStreamFile) async throws -> any ClipboardContentReader {
        guard let reference = selections[selectionID]?[file.id], reference.file == file else { throw ClipboardStreamFailure.unavailable }
        return try LocalClipboardContentReader(url: reference.url, expectedVersion: file.version)
    }
    public func releaseSelection(_ selectionID: UUID) {
        guard let references = selections.removeValue(forKey: selectionID) else { return }
        for reference in references.values where reference.scoped { reference.url.stopAccessingSecurityScopedResource() }
    }
    private func uniqueName(_ requested: String, used: inout Set<String>) -> String {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        var name = requested
        let url = URL(fileURLWithPath: requested)
        var suffix = 2
        while !used.insert(fold(name)).inserted {
            name = url.deletingPathExtension().lastPathComponent + " (\(suffix))" + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
            suffix += 1
        }
        return name
    }
}

private struct FileStamp {
    let size: UInt64
    let version: String
    init(_ value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { throw ClipboardStreamFailure.unsupported }
        size = UInt64(value.st_size)
        let fingerprint = "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
        version = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func path(_ url: URL) throws -> Self {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0, &value) }) == 0 else { throw ClipboardStreamFailure.unavailable }
        return try Self(value)
    }
    static func descriptor(_ fd: Int32) throws -> Self {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw ClipboardStreamFailure.ioFailure }
        return try Self(value)
    }
}

private actor LocalClipboardContentReader: ClipboardContentReader {
    private let url: URL
    private let expectedVersion: String
    private let handle: FileHandle
    private let scoped: Bool
    private var closed = false
    init(url: URL, expectedVersion: String) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw ClipboardStreamFailure.unavailable
        }
        do {
            guard try FileStamp.descriptor(fd).version == expectedVersion else { throw ClipboardStreamFailure.changed }
        } catch {
            Darwin.close(fd)
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        self.url = url; self.expectedVersion = expectedVersion; self.scoped = scoped
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func read(offset: UInt64, length: Int) throws -> Data {
        try validate()
        guard length >= 0, length <= ClipboardStreamLimits.default.maximumReadBytes else { throw ClipboardStreamFailure.invalidRequest }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: length) ?? Data()
        try validate()
        return data
    }
    func digest() async throws -> Data {
        try validate()
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var cursor: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard !closed else { throw ClipboardStreamFailure.cancelled }
            try handle.seek(toOffset: cursor)
            let bytes = try handle.read(upToCount: ClipboardStreamLimits.default.maximumReadBytes) ?? Data()
            if bytes.isEmpty { break }
            hasher.update(data: bytes)
            cursor += UInt64(bytes.count)
            await Task.yield()
            try validate()
        }
        return Data(hasher.finalize())
    }
    func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
    private func validate() throws {
        guard !closed else { throw ClipboardStreamFailure.cancelled }
        guard try FileStamp.descriptor(handle.fileDescriptor).version == expectedVersion,
              try FileStamp.path(url).version == expectedVersion else { throw ClipboardStreamFailure.changed }
    }
}
