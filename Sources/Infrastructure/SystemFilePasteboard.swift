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
    private let stream: AsyncStream<PasteboardFileSelection>
    private let continuation: AsyncStream<PasteboardFileSelection>.Continuation
    private var monitorTask: Task<Void, Never>?
    private var lastObservedChangeCount: Int

    public init(
        pasteboard: NSPasteboard = .general,
        pollingInterval: Duration = .milliseconds(350)
    ) {
        self.pasteboard = pasteboard
        self.pollingInterval = pollingInterval
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
        guard !urls.isEmpty else { return }
        let items = urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(transferID.rawValue.uuidString, forType: Self.originType)
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        lastObservedChangeCount = pasteboard.changeCount
    }

    private func startMonitoringIfNeeded() {
        guard monitorTask == nil else { return }
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
        for item in items {
            guard let value = item.string(forType: .fileURL),
                  let url = URL(string: value),
                  url.isFileURL,
                  seen.insert(url.standardizedFileURL).inserted else { continue }
            urls.append(url.standardizedFileURL)
        }
        guard !urls.isEmpty else { return }
        continuation.yield(PasteboardFileSelection(changeCount: changeCount, urls: urls))
    }
}
