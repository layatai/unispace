import Foundation

public final class DiagnosticLog: @unchecked Sendable {
    public static let settingKey = "DiagnosticLoggingEnabled"
    private static let maximumBytes = 5 * 1_024 * 1_024

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.layatai.unispace.diagnostics", qos: .utility)
    private let defaults: UserDefaults
    private let fileManager: FileManager
    public let fileURL: URL
    private var enabled: Bool

    public init(
        rootURL: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        enabled = defaults.bool(forKey: Self.settingKey)
        let root = rootURL ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory)
            .appendingPathComponent("UniSpace/Logs", isDirectory: true)
        fileURL = root.appendingPathComponent("diagnostics.log")
    }

    public var isEnabled: Bool { lock.withLock { enabled } }

    public func setEnabled(_ value: Bool) {
        lock.withLock { enabled = value }
        defaults.set(value, forKey: Self.settingKey)
        if value { record("Diagnostic logging enabled") }
    }

    public func record(_ message: String) {
        guard isEnabled else { return }
        let line = "[\(Date().formatted(.iso8601))] \(message)\n"
        queue.async { [fileManager, fileURL] in
            do {
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
                    .intValue ?? 0
                if size >= Self.maximumBytes { try Data().write(to: fileURL, options: .atomic) }
                if !fileManager.fileExists(atPath: fileURL.path) {
                    fileManager.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } catch {
                // Diagnostics must never alter control behavior.
            }
        }
    }

    public func flush() { queue.sync {} }
}
