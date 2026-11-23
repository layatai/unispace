import AppKit
import Foundation
import Testing
import UniSpaceApplication
import UniSpaceClipboardProviderShared
import UniSpaceDomain
@testable import UniSpaceInfrastructure

/// Exercises the File Provider request bridge against a temporary directory;
/// registering a real File Provider domain is out of reach for unit tests.
@MainActor
struct FileProviderClipboardAdapterTests {
    @MainActor private struct Fixture {
        let root: URL
        let adapter: FileProviderClipboardAdapter
        let pasteboard: NSPasteboard
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("UniSpace-bridge-\(UUID())")
            for name in ["requests", "responses", "cancel", "downloads"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            pasteboard = NSPasteboard(name: .init("UniSpace-bridge-\(UUID())"))
            let root = self.root
            adapter = FileProviderClipboardAdapter(pasteboard: pasteboard, storageRoot: { root })
        }
        func request(_ fetch: ClipboardProviderFetch) throws {
            try ClipboardProviderStorage.write(fetch, to: root.appendingPathComponent("requests/\(fetch.id.uuidString).json"))
        }
        func response(_ id: UUID) async throws -> ClipboardProviderResult? {
            let url = root.appendingPathComponent("responses/\(id.uuidString).json")
            for _ in 0..<200 {
                if let data = try? Data(contentsOf: url) { return try JSONDecoder().decode(ClipboardProviderResult.self, from: data) }
                try await Task.sleep(for: .milliseconds(5))
            }
            return nil
        }
        func cleanUp() { pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    }

    private func file(named name: String = "notes.txt") -> ClipboardProviderFile {
        ClipboardProviderFile(peerID: UUID(), selectionID: UUID(), fileID: UUID(), name: name, size: 5,
                              contentType: "public.plain-text", version: "v1")
    }

    @Test func unknownItemsAnswerUnavailableAndMalformedRequestsAreIgnored() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let unknown = ClipboardProviderFetch(itemID: "missing")
        try fixture.request(unknown)
        // A request whose file name does not match its ID is not processed or consumed.
        let mismatched = fixture.root.appendingPathComponent("requests/\(UUID().uuidString).json")
        try ClipboardProviderStorage.write(ClipboardProviderFetch(itemID: "x"), to: mismatched)
        try Data("not json".utf8).write(to: fixture.root.appendingPathComponent("requests/\(UUID().uuidString).json"))
        fixture.adapter.scan()
        let result = try #require(try await fixture.response(unknown.id))
        #expect(result.failure == "unavailable")
        #expect(result.contentsPath == nil)
        #expect(FileManager.default.fileExists(atPath: mismatched.path))
        await fixture.adapter.stop()
    }

    @Test func downloadsAnswerWithContentsOrTypedFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let good = file(), bad = file(named: "broken.txt")
        fixture.adapter.files = [good.itemID: good, bad.itemID: bad]
        fixture.adapter.onDownload = { file, destination, _ in
            guard file.name == "notes.txt" else { throw ClipboardStreamFailure.changed }
            try Data("hello".utf8).write(to: destination)
        }
        let goodRequest = ClipboardProviderFetch(itemID: good.itemID)
        let badRequest = ClipboardProviderFetch(itemID: bad.itemID)
        try fixture.request(goodRequest); try fixture.request(badRequest)
        fixture.adapter.scan()

        let delivered = try #require(try await fixture.response(goodRequest.id))
        let path = try #require(delivered.contentsPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("hello".utf8))
        let failed = try #require(try await fixture.response(badRequest.id))
        #expect(failed.failure == "changed")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("downloads/\(badRequest.id.uuidString)").path))
        await fixture.adapter.stop()
    }

    @Test func cancelMarkerStopsAnInFlightDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let slow = file()
        fixture.adapter.files = [slow.itemID: slow]
        fixture.adapter.onDownload = { _, _, _ in try await Task.sleep(for: .seconds(30)) }
        let request = ClipboardProviderFetch(itemID: slow.itemID)
        try fixture.request(request)
        fixture.adapter.scan()
        let marker = fixture.root.appendingPathComponent("cancel/\(request.id.uuidString)")
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        fixture.adapter.scan()
        #expect(!FileManager.default.fileExists(atPath: marker.path), "The cancel marker is consumed")
        let result = try #require(try await fixture.response(request.id))
        #expect(result.failure != nil, "A cancelled download answers with a failure, never contents")
        await fixture.adapter.stop()
    }

    @Test func withdrawLeavesForeignPasteboardContentsAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("someone else", forType: .string)
        await fixture.adapter.withdraw(UUID(), from: DeviceID())
        #expect(fixture.pasteboard.string(forType: .string) == "someone else")
    }

    @Test func disabledDomainBlocksPublishAndReportsWhoseFilesWait() async throws {
        let pasteboard = NSPasteboard(name: .init("UniSpace-disabled-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniSpace-disabled-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = FileProviderClipboardAdapter(pasteboard: pasteboard, storageRoot: { root }, domainEnabled: { false })
        var states: [Bool] = []
        var blocked: [DeviceID] = []
        adapter.enabledChanged = { states.append($0) }
        adapter.publishBlocked = { blocked.append($0) }
        let peer = DeviceID()
        let selection = ClipboardStreamSelection(epoch: UUID(), generation: 1,
            files: [ClipboardStreamFile(name: "notes.txt", size: 5, version: "v1")])

        await #expect(throws: ClipboardStreamFailure.unsupported) {
            try await adapter.publish(selection, from: peer)
        }
        #expect(blocked == [peer])
        #expect(states == [false])
        #expect(adapter.isEnabled == false)
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
        // A repeated query with no change does not report again.
        #expect(await adapter.refreshAvailability() == false)
        #expect(states == [false])
    }

    @Test func enablingTheDomainIsReportedOnTheNextQuery() async {
        let enabled = LockedFlag(false)
        let adapter = FileProviderClipboardAdapter(pasteboard: NSPasteboard(name: .init("UniSpace-toggle-\(UUID())")),
            storageRoot: { FileManager.default.temporaryDirectory }, domainEnabled: { enabled.value })
        var states: [Bool] = []
        adapter.enabledChanged = { states.append($0) }
        #expect(await adapter.refreshAvailability() == false)
        enabled.value = true
        #expect(await adapter.refreshAvailability() == true)
        #expect(states == [false, true])
    }

    @Test func failedDomainQueryCountsAsDisabled() async {
        struct QueryFailed: Error {}
        let adapter = FileProviderClipboardAdapter(pasteboard: NSPasteboard(name: .init("UniSpace-fail-\(UUID())")),
            storageRoot: { FileManager.default.temporaryDirectory }, domainEnabled: { throw QueryFailed() })
        #expect(await adapter.refreshAvailability() == false)
        #expect(adapter.isEnabled == false)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
