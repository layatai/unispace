import AppKit
import Foundation
import UniSpaceApplication
import UniSpaceDomain

@MainActor
public final class SystemClipboardService: ClipboardService {
    public static let originType = NSPasteboard.PasteboardType(
        "com.layatai.unispace.clipboard-origin"
    )

    private let pasteboard: NSPasteboard
    private let pollingInterval: Duration
    private let limits: ClipboardLimits
    private let stream: AsyncStream<ClipboardObservation>
    private let continuation: AsyncStream<ClipboardObservation>.Continuation
    private var monitorTask: Task<Void, Never>?
    private var lastObservedChangeCount: Int

    public init(
        pasteboard: NSPasteboard = .general,
        pollingInterval: Duration = .milliseconds(300),
        limits: ClipboardLimits = .default
    ) {
        self.pasteboard = pasteboard
        self.pollingInterval = pollingInterval
        self.limits = limits
        lastObservedChangeCount = pasteboard.changeCount
        var captured: AsyncStream<ClipboardObservation>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    deinit {
        monitorTask?.cancel()
        continuation.finish()
    }

    public func events() -> AsyncStream<ClipboardObservation> {
        startMonitoringIfNeeded()
        return stream
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        lastObservedChangeCount = pasteboard.changeCount
    }

    public func apply(_ payload: ClipboardPayload) {
        guard let representations = try? ClipboardPayload.normalizedRepresentations(
            payload.representations,
            limits: limits
        ), !representations.isEmpty else { return }

        let item = NSPasteboardItem()
        var plainText: String?
        var link: String?
        for representation in representations {
            switch representation.kind {
            case .plainText:
                plainText = representation.value
            case .url:
                link = representation.value
            }
        }

        if let link {
            item.setString(link, forType: .URL)
            item.setString(plainText ?? link, forType: .string)
        } else if let plainText {
            item.setString(plainText, forType: .string)
        }
        item.setString(payload.payloadID.rawValue.uuidString, forType: Self.originType)

        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return }
        lastObservedChangeCount = pasteboard.changeCount
    }

    func pollNowForTesting() {
        poll()
    }

    private func startMonitoringIfNeeded() {
        guard monitorTask == nil else { return }
        lastObservedChangeCount = pasteboard.changeCount
        monitorTask = Task(priority: .high) { [weak self] in
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

        // Finder commonly includes a plain-text representation beside each file
        // URL. File continuity owns that clipboard change; treating the fallback
        // text as shared clipboard content can race with and replace the file drop.
        if items.contains(where: {
            $0.types.contains(.fileURL) ||
                $0.string(forType: SystemFilePasteboard.originType) != nil
        }) {
            lastObservedChangeCount = changeCount
            return
        }

        do {
            for item in items {
                if item.string(forType: Self.originType) != nil {
                    lastObservedChangeCount = changeCount
                    return
                }
                let representations = try supportedRepresentations(from: item)
                guard !representations.isEmpty else { continue }
                lastObservedChangeCount = changeCount
                continuation.yield(ClipboardObservation(
                    changeCount: changeCount,
                    representations: representations
                ))
                return
            }
            lastObservedChangeCount = changeCount
        } catch {
            // Unsupported or oversized clipboard data is intentionally ignored.
            lastObservedChangeCount = changeCount
        }
    }

    private func supportedRepresentations(
        from item: NSPasteboardItem
    ) throws -> [ClipboardRepresentation] {
        guard !item.types.contains(.fileURL) else { return [] }
        var values: [ClipboardRepresentation] = []
        var link: String?

        if let value = item.string(forType: .URL), isPortableURL(value) {
            link = value
            values.append(ClipboardRepresentation(kind: .url, value: value))
        }

        if let text = item.string(forType: .string), !text.isEmpty {
            values.append(ClipboardRepresentation(kind: .plainText, value: text))
            if link == nil, isPortableURL(text) {
                values.append(ClipboardRepresentation(kind: .url, value: text))
            }
        } else if let link {
            values.append(ClipboardRepresentation(kind: .plainText, value: link))
        }

        return try ClipboardPayload.normalizedRepresentations(values, limits: limits)
    }

    private func isPortableURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              !scheme.isEmpty,
              components.url?.isFileURL != true else { return false }
        return true
    }
}
