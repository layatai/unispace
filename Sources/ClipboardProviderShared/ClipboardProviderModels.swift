import Foundation

public enum ClipboardProviderStorage {
    public static let group = "Y69F3DRK44.com.layatai.unispace.clipboard"
    public static var root: URL {
        get throws {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                throw CocoaError(.fileReadNoPermission)
            }
            return url.appendingPathComponent("ClipboardBridge", isDirectory: true)
        }
    }
    public static func prepare() throws {
        let root = try root
        for name in ["requests", "responses", "cancel", "downloads"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func manifest() throws -> ClipboardProviderManifest {
        let path = try root.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return .init(files: []) }
        return try JSONDecoder().decode(ClipboardProviderManifest.self, from: Data(contentsOf: path))
    }
}

public struct ClipboardProviderFile: Codable, Equatable, Sendable {
    public let itemID: String
    public let peerID: UUID
    public let selectionID: UUID
    public let fileID: UUID
    public let name: String
    public let size: UInt64
    public let contentType: String
    public let version: String
    public init(peerID: UUID, selectionID: UUID, fileID: UUID, name: String, size: UInt64, contentType: String, version: String) {
        itemID = "\(peerID.uuidString)/\(selectionID.uuidString)/\(fileID.uuidString)"
        self.peerID = peerID; self.selectionID = selectionID; self.fileID = fileID
        self.name = name; self.size = size; self.contentType = contentType; self.version = version
    }
}
public struct ClipboardProviderManifest: Codable, Sendable {
    public let files: [ClipboardProviderFile]
    public init(files: [ClipboardProviderFile]) { self.files = files }
}
public struct ClipboardProviderFetch: Codable, Sendable {
    public let id: UUID
    public let itemID: String
    public init(id: UUID = UUID(), itemID: String) { self.id = id; self.itemID = itemID }
}
public struct ClipboardProviderResult: Codable, Sendable {
    public let id: UUID
    public let contentsPath: String?
    public let failure: String?
    public init(id: UUID, contentsPath: String? = nil, failure: String? = nil) {
        self.id = id; self.contentsPath = contentsPath; self.failure = failure
    }
}
