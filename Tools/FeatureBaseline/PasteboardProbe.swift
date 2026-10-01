import AppKit
import CryptoKit
import Foundation

// Reads only disposable test markers into stdout. Private snapshots stay local.
let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first else { exit(2) }
let board = NSPasteboard.general
let textOrigin = NSPasteboard.PasteboardType("com.layatai.unispace.clipboard-origin")
let fileOrigin = NSPasteboard.PasteboardType("com.layatai.unispace.file-transfer-origin")
func output(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
func argument(_ index: Int) -> String {
    guard arguments.indices.contains(index) else { exit(2) }
    return arguments[index]
}
switch mode {
case "snapshot":
    let path = argument(1)
    let items = (board.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
            item.data(forType: type).map { (type.rawValue, $0) }
        })
    }
    // The runner creates a private directory before invoking this helper.
    umask(0o077)
    try PropertyListEncoder().encode(items).write(to: URL(fileURLWithPath: path), options: .atomic)
    try output(["saved": true])
case "text", "url":
    let token = argument(1)
    guard token.contains("UniSpaceVerify-") else { exit(2) }
    let item = NSPasteboardItem()
    item.setString(token, forType: .string)
    if mode == "url" { item.setString(token, forType: .URL) }
    board.clearContents()
    try output(["written": board.writeObjects([item])])
case "check":
    let token = argument(1)
    try output(["matches": board.string(forType: .string) == token,
                "urlMatches": board.string(forType: .URL) == token,
                "unispaceOrigin": board.string(forType: textOrigin) != nil])
case "files":
    let prefix = argument(1)
    guard prefix.hasPrefix("UniSpaceVerify-") else { exit(2) }
    let urls = (board.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }
        .compactMap(URL.init(string:))
    let files = try urls.filter { $0.lastPathComponent.hasPrefix(prefix) }.map { url -> [String: Any] in
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return ["name": url.lastPathComponent, "path": url.path, "bytes": data.count,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }
    try output(["files": files, "fileCount": urls.count,
                "unispaceOrigin": board.string(forType: fileOrigin) != nil])
case "restore":
    let path = argument(1)
    let prefix = argument(2)
    guard prefix.hasPrefix("UniSpaceVerify-") else { exit(2) }
    let text = board.string(forType: .string) ?? ""
    let files = (board.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }
    guard text.hasPrefix(prefix) || text.hasPrefix("https://example.com/" + prefix)
            || (!files.isEmpty && files.allSatisfy { URL(string: $0)?.lastPathComponent.hasPrefix(prefix) == true }) else {
        try output(["restored": false, "preservedNewerClipboard": true])
        exit(0)
    }
    let values = try PropertyListDecoder().decode([[String: Data]].self,
        from: Data(contentsOf: URL(fileURLWithPath: path)))
    let items = values.map { entry in
        let item = NSPasteboardItem()
        for (type, data) in entry { item.setData(data, forType: .init(type)) }
        // Prevent restoration from sending the user's original private content.
        item.setString("verification-restore", forType: textOrigin)
        item.setString("verification-restore", forType: fileOrigin)
        return item
    }
    board.clearContents()
    try output(["restored": items.isEmpty || board.writeObjects(items)])
default:
    exit(2)
}
