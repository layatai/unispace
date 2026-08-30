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
        try? publishFilesChecked(urls, transferID: transferID)
    }

    public func publishFilesChecked(_ urls: [URL], transferID: TransferID) throws {
        guard let urls = validatedLocalFiles(urls) else {
            throw FilePasteboardPublicationError.invalidFileSet
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls.map { $0 as NSURL }) else {
            throw FilePasteboardPublicationError.writeRejected
        }
        guard pasteboard.setString(
            transferID.rawValue.uuidString,
            forType: Self.originType
        ) else {
            pasteboard.clearContents()
            throw FilePasteboardPublicationError.writeRejected
        }
        lastObservedChangeCount = pasteboard.changeCount
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
        lastObservedChangeCount = changeCount
        let items = pasteboard.pasteboardItems ?? []
        guard !items.contains(where: { $0.string(forType: Self.originType) != nil }) else {
            return
        }

        var urls: [URL] = []
        var seen = Set<URL>()
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        for object in objects {
            guard let value = object as? NSURL else { continue }
            let url = value as URL
            guard url.isFileURL else { continue }
            let normalized = url.standardizedFileURL
            guard seen.insert(normalized).inserted else { continue }
            urls.append(normalized)
        }
        guard !urls.isEmpty else { return }
        continuation.yield(PasteboardFileSelection(changeCount: changeCount, urls: urls))
    }

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
                      .isSymbolicLinkKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            normalized.append(url)
        }
        return normalized.isEmpty ? nil : normalized
    }

    func pollNowForTesting() {
        poll()
    }
}
