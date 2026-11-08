import Foundation
import FileProvider
import UniformTypeIdentifiers
import UniSpaceClipboardProviderShared

@objc(UniSpaceClipboardFileProvider)
final class ClipboardFileProvider: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    required init(domain: NSFileProviderDomain) { super.init() }
    func invalidate() {}
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        do { completionHandler(try providerItem(identifier), nil) }
        catch { completionHandler(nil, error) }
        return Progress(totalUnitCount: 1)
    }
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        try ClipboardProviderEnumerator(files: ClipboardProviderStorage.manifest().files)
    }
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            let item = try providerItem(itemIdentifier)
            guard let file = item.file else { throw NSFileProviderError(.noSuchItem) }
            progress.totalUnitCount = Int64(file.size)
            let fetch = ClipboardProviderFetch(itemID: file.itemID)
            let root = try ClipboardProviderStorage.root
            try ClipboardProviderStorage.prepare()
            let requestURL = root.appendingPathComponent("requests/\(fetch.id.uuidString).json")
            let replyURL = root.appendingPathComponent("responses/\(fetch.id.uuidString).json")
            let cancelURL = root.appendingPathComponent("cancel/\(fetch.id.uuidString)")
            progress.cancellationHandler = { try? Data().write(to: cancelURL, options: .atomic) }
            try ClipboardProviderStorage.write(fetch, to: requestURL)
            // A native content request is the only operation that creates a fetch.
            // Metadata/enumeration and clipboard publication never use this path.
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(1800)
                while Date() < deadline && !progress.isCancelled {
                    if let bytes = try? Data(contentsOf: replyURL),
                       let result = try? JSONDecoder().decode(ClipboardProviderResult.self, from: bytes), result.id == fetch.id {
                        defer { try? FileManager.default.removeItem(at: replyURL) }
                        if let path = result.contentsPath {
                            let contents = URL(fileURLWithPath: path).standardizedFileURL
                            guard contents.path.hasPrefix(root.appendingPathComponent("downloads").path + "/") else {
                                completionHandler(nil, nil, NSFileProviderError(.noSuchItem)); return
                            }
                            progress.completedUnitCount = progress.totalUnitCount
                            completionHandler(contents, item, nil)
                        } else { completionHandler(nil, nil, NSFileProviderError(.serverUnreachable)) }
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                try? Data().write(to: cancelURL, options: .atomic)
                completionHandler(nil, nil, CocoaError(progress.isCancelled ? .userCancelled : .fileReadUnknown))
            }
        } catch { completionHandler(nil, nil, error) }
        return progress
    }
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions,
                    request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, CocoaError(.featureUnsupported)); return Progress(totalUnitCount: 1)
    }
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, CocoaError(.featureUnsupported)); return Progress(totalUnitCount: 1)
    }
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions,
                    request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(CocoaError(.featureUnsupported)); return Progress(totalUnitCount: 1)
    }
    private func providerItem(_ id: NSFileProviderItemIdentifier) throws -> ClipboardProviderItem {
        if id == .rootContainer || id == .trashContainer { return ClipboardProviderItem(id: id, file: nil) }
        guard let file = try ClipboardProviderStorage.manifest().files.first(where: { $0.itemID == id.rawValue }) else { throw NSFileProviderError(.noSuchItem) }
        return ClipboardProviderItem(id: id, file: file)
    }
}
private final class ClipboardProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    let file: ClipboardProviderFile?
    init(id: NSFileProviderItemIdentifier, file: ClipboardProviderFile?) { itemIdentifier = id; self.file = file }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { file?.name ?? (itemIdentifier == .trashContainer ? ".Trash" : "UniSpace Clipboard") }
    var contentType: UTType { file.map { UTType($0.contentType) ?? .data } ?? .folder }
    var documentSize: NSNumber? { file.map { NSNumber(value: $0.size) } }
    var capabilities: NSFileProviderItemCapabilities { file == nil ? [.allowsContentEnumerating] : [.allowsReading] }
    var contentPolicy: NSFileProviderContentPolicy { .downloadLazily }
    var isUploaded: Bool { true }
    var itemVersion: NSFileProviderItemVersion { .init(contentVersion: Data((file?.version ?? "root").utf8), metadataVersion: Data((file?.itemID ?? "root").utf8)) }
}
private final class ClipboardProviderEnumerator: NSObject, NSFileProviderEnumerator {
    let files: [ClipboardProviderFile]
    init(files: [ClipboardProviderFile]) { self.files = files }
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.didEnumerate(files.map { ClipboardProviderItem(id: .init($0.itemID), file: $0) }); observer.finishEnumerating(upTo: nil)
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        observer.didUpdate(files.map { ClipboardProviderItem(id: .init($0.itemID), file: $0) })
        observer.finishEnumeratingChanges(upTo: .init(Data([1])), moreComing: false)
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) { completionHandler(.init(Data([1]))) }
}
