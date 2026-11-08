import Foundation
import FileProvider
import UniformTypeIdentifiers

enum ProbeStorage {
    static let group = "Y69F3DRK44.com.layatai.unispace.lazy-qa"
    static let domain = NSFileProviderDomain(identifier: .init("lazy-qa"), displayName: "UniSpace Lazy QA")
    static var root: URL {
        get throws {
            guard let value = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                throw NSError(domain: "UniSpace.LazyQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "QA App Group unavailable"])
            }
            return value.appendingPathComponent("lazy-native-qa", isDirectory: true)
        }
    }
    static func record(_ event: String) {
        guard let root = try? root else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("events.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(Date().timeIntervalSince1970) \(event)\n".utf8))
    }
}

final class ProbeItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    init(_ id: NSFileProviderItemIdentifier) { itemIdentifier = id }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { itemIdentifier == .rootContainer ? "UniSpace Lazy QA" : "UniSpaceLazyQA-\(itemIdentifier.rawValue).txt" }
    var contentType: UTType { itemIdentifier == .rootContainer ? .folder : .plainText }
    var capabilities: NSFileProviderItemCapabilities { itemIdentifier == .rootContainer ? [.allowsContentEnumerating] : [.allowsReading] }
    var documentSize: NSNumber? { itemIdentifier == .rootContainer ? nil : NSNumber(value: 65_536) }
    var itemVersion: NSFileProviderItemVersion { .init(contentVersion: Data([1]), metadataVersion: Data([1])) }
    var contentPolicy: NSFileProviderContentPolicy { .downloadLazily }
    var isUploaded: Bool { true }
}
