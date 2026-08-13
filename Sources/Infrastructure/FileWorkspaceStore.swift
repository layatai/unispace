import Foundation
import UniSpaceApplication
import UniSpaceDomain

public final class FileWorkspaceStore: WorkspaceStore, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileManager: FileManager = .default) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = root.appendingPathComponent("UniSpace", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("workspace.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> WorkspaceSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ workspace: WorkspaceSnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workspace)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
