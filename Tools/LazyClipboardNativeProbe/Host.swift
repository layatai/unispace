import AppKit
import FileProvider

@main
struct ProbeHost {
    static func main() {
        let app = NSApplication.shared
        let delegate = ProbeHostDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class ProbeHostDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var status: NSTextField!
    private var original: [[NSPasteboard.PasteboardType: Data]] = []
    private var ownedChangeCount: Int?
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 240), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "UniSpace Lazy File Native QA"
        let button = NSButton(title: "Publish Two Deferred QA Files", target: self, action: #selector(publish))
        button.frame = NSRect(x: 24, y: 150, width: 360, height: 38)
        status = NSTextField(wrappingLabelWithString: "Registering the disposable QA File Provider...")
        status.frame = NSRect(x: 24, y: 30, width: 530, height: 110)
        window.contentView?.addSubview(button); window.contentView?.addSubview(status)
        window.center(); window.makeKeyAndOrderFront(nil)
        NSFileProviderManager.add(ProbeStorage.domain) { error in
            DispatchQueue.main.async {
                self.status.stringValue = error.map { "Registration failed: \($0.localizedDescription)" } ?? "Provider registered. Publish files, then paste into a disposable Finder folder."
            }
            ProbeStorage.record(error.map { "register-error \($0)" } ?? "registered")
        }
    }
    @objc private func publish() {
        guard let manager = NSFileProviderManager(for: ProbeStorage.domain) else { return }
        manager.signalEnumerator(for: .rootContainer) { _ in }
        Task { @MainActor in
            do {
                let first = try await manager.getUserVisibleURL(for: .init("one"))
                let second = try await manager.getUserVisibleURL(for: .init("two"))
                let scoped = [first, second].filter { $0.startAccessingSecurityScopedResource() }
                defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
                let board = NSPasteboard.general
                original = (board.pasteboardItems ?? []).map { item in
                    Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
                }
                board.clearContents()
                guard board.writeObjects([first as NSURL, second as NSURL]) else { throw CocoaError(.fileWriteUnknown) }
                let marker = NSPasteboard.PasteboardType("com.layatai.unispace.file-transfer-origin")
                board.addTypes([marker], owner: nil)
                board.setString("lazy-qa", forType: marker)
                ownedChangeCount = board.changeCount
                ProbeStorage.record("CLIPBOARD-PUBLISHED")
                status.stringValue = "Two QA paths published. No contents should be fetched until paste. Event log: \(try ProbeStorage.root.path)/events.log"
            } catch { status.stringValue = error.localizedDescription; ProbeStorage.record("publish-error \(error)") }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        let board = NSPasteboard.general
        guard ownedChangeCount == board.changeCount else { return }
        let items = original.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            item.setString("qa-restore", forType: .init("com.layatai.unispace.file-transfer-origin"))
            item.setString("qa-restore", forType: .init("com.layatai.unispace.clipboard-origin"))
            return item
        }
        board.clearContents(); board.writeObjects(items)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
