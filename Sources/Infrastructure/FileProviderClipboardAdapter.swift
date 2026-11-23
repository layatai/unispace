import AppKit
@preconcurrency import FileProvider
import Foundation
import UniSpaceApplication
import UniSpaceDomain
import UniSpaceClipboardProviderShared

@MainActor
public final class FileProviderClipboardAdapter: ClipboardVirtualFileAdapter {
    public static let domain = NSFileProviderDomain(identifier: .init("clipboard-v2"), displayName: "UniSpace Clipboard")
    /// Reports whether the user has the UniSpace Clipboard domain turned on.
    /// macOS lets users disable a File Provider domain; while it is off,
    /// files copied on a peer cannot be pasted on this Mac.
    public var enabledChanged: (@MainActor @Sendable (Bool) -> Void)?
    /// Called when a peer offered files that could not be published because
    /// the domain is disabled, so the UI can say whose files are waiting.
    public var publishBlocked: (@MainActor @Sendable (DeviceID) -> Void)?
    public var onDownload: (@Sendable (ClipboardProviderFile, URL, @Sendable @escaping (UInt64, UInt64) async -> Void) async throws -> Void)?
    private let pasteboard: NSPasteboard
    /// Internal for tests; published files keyed by provider item ID.
    var files: [String: ClipboardProviderFile] = [:]
    private let storageRoot: () throws -> URL
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var scanner: Task<Void, Never>?
    private var ownedChangeCount: Int?
    private let domainEnabled: @MainActor @Sendable () async throws -> Bool
    public private(set) var isEnabled: Bool?
    public convenience init(pasteboard: NSPasteboard = .general) {
        self.init(pasteboard: pasteboard, storageRoot: { try ClipboardProviderStorage.root }, domainEnabled: {
            try ClipboardProviderStorage.prepare()
            // Adding an existing domain is a no-op; it keeps UniSpace listed
            // under File Providers in System Settings so the user can enable it.
            try await NSFileProviderManager.add(Self.domain)
            return try await Self.isDomainUserEnabled(Self.domain.identifier)
        })
    }
    /// Tests point the bridge at a temporary directory instead of the app group
    /// and replace the system domain query.
    init(pasteboard: NSPasteboard, storageRoot: @escaping () throws -> URL,
         domainEnabled: @escaping @MainActor @Sendable () async throws -> Bool = { true }) {
        self.pasteboard = pasteboard; self.storageRoot = storageRoot; self.domainEnabled = domainEnabled
    }
    /// Queries the domain state and reports changes. Failures count as disabled
    /// because remote files cannot be pasted either way.
    @discardableResult
    public func refreshAvailability() async -> Bool {
        let enabled = (try? await domainEnabled()) ?? false
        if isEnabled != enabled {
            isEnabled = enabled
            enabledChanged?(enabled)
        }
        return enabled
    }
    public func prepare() async throws {
        guard await refreshAvailability() else { throw ClipboardStreamFailure.unsupported }
        startScanner()
    }
    /// Reduces the non-Sendable domain list to a Bool inside the callback so
    /// nothing non-Sendable crosses back onto the main actor (Swift 6.1).
    private nonisolated static func isDomainUserEnabled(_ identifier: NSFileProviderDomainIdentifier) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: domains.contains { $0.identifier == identifier && $0.userEnabled })
                }
            }
        }
    }
    public func publish(_ selection: ClipboardStreamSelection, from peer: DeviceID) async throws {
        try selection.validate()
        do {
            try await prepare()
        } catch {
            publishBlocked?(peer)
            throw error
        }
        guard let manager = NSFileProviderManager(for: Self.domain) else { throw ClipboardStreamFailure.unsupported }
        let additions = selection.files.map { file in
            ClipboardProviderFile(peerID: peer.rawValue, selectionID: selection.id, fileID: file.id,
                name: file.name, size: file.size, contentType: file.contentType, version: file.version)
        }
        for file in additions { files[file.itemID] = file }
        try persistManifest()
        try await manager.signalEnumerator(for: .rootContainer)
        var urls: [URL] = []
        for file in additions { urls.append(try await manager.getUserVisibleURL(for: .init(file.itemID))) }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls.map { $0 as NSURL }) else { throw ClipboardStreamFailure.ioFailure }
        pasteboard.addTypes([SystemFilePasteboard.originType], owner: nil)
        guard pasteboard.setString(selection.id.uuidString, forType: SystemFilePasteboard.originType) else {
            throw ClipboardStreamFailure.ioFailure
        }
        ownedChangeCount = pasteboard.changeCount
    }
    public func withdraw(_ selectionID: UUID, from peer: DeviceID) async {
        // Dataless metadata remains available for already pinned native reads.
        // New content opens are still rejected by the source selection registry.
        if ownedChangeCount == pasteboard.changeCount,
           pasteboard.string(forType: SystemFilePasteboard.originType) == selectionID.uuidString {
            pasteboard.clearContents(); ownedChangeCount = nil
        }
    }
    public func stop() async {
        scanner?.cancel(); scanner = nil
        for job in jobs.values { job.cancel() }; jobs.removeAll()
    }
    private func persistManifest() throws {
        try ClipboardProviderStorage.write(ClipboardProviderManifest(files: Array(files.values)),
            to: storageRoot().appendingPathComponent("manifest.json"))
    }
    private func startScanner() {
        guard scanner == nil else { return }
        scanner = Task { [weak self] in
            while !Task.isCancelled {
                self?.scan()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    func scan() {
        guard let root = try? storageRoot(),
              let requests = try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("requests"), includingPropertiesForKeys: nil) else { return }
        for url in requests where url.pathExtension == "json" {
            guard let bytes = try? Data(contentsOf: url), let request = try? JSONDecoder().decode(ClipboardProviderFetch.self, from: bytes),
                  request.id.uuidString == url.deletingPathExtension().lastPathComponent, jobs[request.id] == nil, jobs.count < 4 else { continue }
            try? FileManager.default.removeItem(at: url)
            guard let file = files[request.itemID], let onDownload else {
                try? respond(.init(id: request.id, failure: "unavailable")); continue
            }
            jobs[request.id] = Task { [weak self] in
                let directory = root.appendingPathComponent("downloads/\(request.id.uuidString)")
                let output = directory.appendingPathComponent(file.name)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try await onDownload(file, output) { _, _ in }
                    try self?.respond(.init(id: request.id, contentsPath: output.path))
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    try? self?.respond(.init(id: request.id, failure: (error as? ClipboardStreamFailure)?.rawValue ?? "ioFailure"))
                }
                self?.jobs.removeValue(forKey: request.id)
            }
        }
        for (id, job) in jobs where FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel/\(id.uuidString)").path) {
            job.cancel(); try? FileManager.default.removeItem(at: root.appendingPathComponent("cancel/\(id.uuidString)"))
        }
    }
    private func respond(_ value: ClipboardProviderResult) throws {
        try ClipboardProviderStorage.write(value, to: storageRoot().appendingPathComponent("responses/\(value.id.uuidString).json"))
    }
}
