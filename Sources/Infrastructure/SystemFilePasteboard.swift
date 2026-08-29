import AppKit
import Foundation
import UniSpaceApplication
import UniSpaceDomain

@MainActor
public final class SystemFilePasteboard: FilePasteboard {
    public static let originType = NSPasteboard.PasteboardType(
        "com.layatai.unispace.file-transfer-origin"
    )

    private let pasteboard: NSPasteboard
    private let pollingInterval: Duration
    private let fileManager: FileManager
    private let stream: AsyncStream<PasteboardFileSelection>
    private let continuation: AsyncStream<PasteboardFileSelection>.Continuation
    private var monitorTask: Task<Void, Never>?
    private var lastObservedChangeCount: Int

    public init(
        pasteboard: NSPasteboard = .general,
        pollingInterval: Duration = .milliseconds(350),
        fileManager: FileManager = .default
    ) {
        self.pasteboard = pasteboard
        self.pollingInterval = pollingInterval
        self.fileManager = fileManager
        lastObservedChangeCount = pasteboard.changeCount
        var captured: AsyncStream<PasteboardFileSelection>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    deinit {
        monitorTask?.cancel()
        continuation.finish()
    }

    public func events() -> AsyncStream<PasteboardFileSelection> {
        startMonitoringIfNeeded()
        return stream
    }

    public func publishFiles(_ urls: [URL], transferID: TransferID) {
        guard let urls = validatedLocalFiles(urls) else { return }
        let items: [NSPasteboardItem] = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(transferID.rawValue.uuidString, forType: Self.originType)
            return item
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { return }
        lastObservedChangeCount = pasteboard.changeCount
    }

    func pollNowForTesting() {
        poll()
    }

    private func startMonitoringIfNeeded() {
        guard monitorTask == nil else { return }
        lastObservedChangeCount = pasteboard.changeCount
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.pollingInterval)
                guard !Task.isCancelled else { return }
                self.poll()
            }
        }
    }

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastObservedChangeCount else { return }
        let items = pasteboard.pasteboardItems ?? []

        // A completed incoming transfer writes its own marker. Consuming it as a
        // new Finder copy would immediately offer the same files back to the peer.
        if items.contains(where: { $0.string(forType: Self.originType) != nil }) {
            lastObservedChangeCount = changeCount
            return
        }

        // Do not interpret a plain-text `file://` string as a Finder file copy.
        guard items.contains(where: { $0.types.contains(.fileURL) }) else {
            lastObservedChangeCount = changeCount
            return
        }

        var urls: [URL] = []
        var seen = Set<URL>()
        for item in items {
            guard item.types.contains(.fileURL),
                  let value = item.string(forType: .fileURL),
                  let url = URL(string: value),
                  url.isFileURL else { continue }
            let normalized = url.standardizedFileURL
            guard seen.insert(normalized).inserted else { continue }
            urls.append(normalized)
        }

        lastObservedChangeCount = changeCount
        guard !urls.isEmpty else { return }
        continuation.yield(PasteboardFileSelection(changeCount: changeCount, urls: urls))
    }

    /// Only publish a complete set of existing regular files. This keeps Finder
    /// from receiving a partially valid selection when one staged URL was removed
    /// or replaced between transfer verification and pasteboard publication.
    private func validatedLocalFiles(_ urls: [URL]) -> [URL]? {
        guard !urls.isEmpty else { return nil }
        var normalized: [URL] = []
        var seen = Set<URL>()

        for candidate in urls {
            guard candidate.isFileURL else { return nil }
            let url = candidate.standardizedFileURL
            guard seen.insert(url).inserted else { continue }
            guard fileManager.fileExists(atPath: url.path),
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            normalized.append(url)
        }

        return normalized.isEmpty ? nil : normalized
    }
}
