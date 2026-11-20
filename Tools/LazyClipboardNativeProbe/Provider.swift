import Foundation
import FileProvider

@objc(UniSpaceQAProvider)
final class ProbeProvider: NSObject, NSFileProviderReplicatedExtension {
    required init(domain: NSFileProviderDomain) { super.init(); ProbeStorage.record("provider-init") }
    func invalidate() { ProbeStorage.record("provider-invalidated") }
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        ProbeStorage.record("metadata \(identifier.rawValue)")
        completionHandler(ProbeItem(identifier), nil)
        return Progress(totalUnitCount: 1)
    }
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 65_536)
        ProbeStorage.record("CONTENT-REQUEST \(itemIdentifier.rawValue) system=\(request.isSystemRequest) viewer=\(request.isFileViewerRequest)")
        do {
            let root = try ProbeStorage.root
            let url = root.appendingPathComponent("content-\(UUID()).txt")
            try Data(repeating: 97, count: 65_536).write(to: url)
            ProbeStorage.record("CONTENT-BYTES 65536")
            completionHandler(url, ProbeItem(itemIdentifier), nil)
            progress.completedUnitCount = 65_536
        } catch { completionHandler(nil, nil, error) }
        return progress
    }
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        ProbeStorage.record("enumerator \(containerItemIdentifier.rawValue)")
        return ProbeEnumerator()
    }
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, CocoaError(.featureUnsupported)); return Progress(totalUnitCount: 1)
    }
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, CocoaError(.featureUnsupported)); return Progress(totalUnitCount: 1)
    }
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(CocoaError(.featureUnsupported)); return Progress(totalUnitCount: 1)
    }
}

final class ProbeEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.didEnumerate([ProbeItem(.init("one")), ProbeItem(.init("two"))])
        observer.finishEnumerating(upTo: nil)
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: .init(Data([1])), moreComing: false)
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) { completionHandler(.init(Data([1]))) }
}
