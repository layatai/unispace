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
}
