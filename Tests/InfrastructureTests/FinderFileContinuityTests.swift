import AppKit
import Foundation
import XCTest
import UniSpaceApplication
import UniSpaceDomain
@testable import UniSpaceInfrastructure

@MainActor
final class FinderFileContinuityTests: XCTestCase {
    func testSystemFilePasteboardObservesMultipleFinderURLsOnce() async throws {
        let fixture = try TemporaryFileFixture(names: ["Alpha.txt", "Beta.txt"])
        defer { fixture.remove() }
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        let service = SystemFilePasteboard(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        let recorder = FileSelectionRecorder()
        let stream = service.events()
        let observationTask = Task { @MainActor in
            for await value in stream {
                await recorder.append(value)
            }
        }
        defer { observationTask.cancel() }

        let items = fixture.urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))

        service.pollNowForTesting()
        let observed = await eventually { await recorder.count == 1 }
        XCTAssertTrue(observed)
        let observations = await recorder.values
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].urls, fixture.urls.map(\.standardizedFileURL))

        service.pollNowForTesting()
        try await Task.sleep(for: .milliseconds(50))
        let countAfterSecondPoll = await recorder.count
        XCTAssertEqual(countAfterSecondPoll, 1)
    }

    func testPublishingVerifiedFilesCreatesFinderURLsAndDoesNotEcho() async throws {
        let fixture = try TemporaryFileFixture(names: ["One.txt", "Two.txt"])
        defer { fixture.remove() }
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        let service = SystemFilePasteboard(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        let recorder = FileSelectionRecorder()
        let stream = service.events()
        let observationTask = Task { @MainActor in
            for await value in stream {
                await recorder.append(value)
            }
        }
        defer { observationTask.cancel() }

        let transferID = TransferID()
        service.publishFiles(fixture.urls, transferID: transferID)
        service.pollNowForTesting()
        try await Task.sleep(for: .milliseconds(50))

        let echoedCount = await recorder.count
        XCTAssertEqual(echoedCount, 0)
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy {
            $0.string(forType: SystemFilePasteboard.originType) == transferID.rawValue.uuidString
        })
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        let urls = objects.compactMap { object -> URL? in
            guard let value = object as? NSURL else { return nil }
            return value as URL
        }
        XCTAssertEqual(urls.map(\.standardizedFileURL), fixture.urls.map(\.standardizedFileURL))
    }

    func testPublishingAnInvalidSetPreservesTheExistingClipboard() throws {
        let fixture = try TemporaryFileFixture(names: ["Valid.txt"])
        defer { fixture.remove() }
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("sentinel", forType: .string))
        let service = SystemFilePasteboard(pasteboard: pasteboard)
        let missing = fixture.root.appendingPathComponent("Missing.txt")

        service.publishFiles([fixture.urls[0], missing], transferID: TransferID())

        XCTAssertEqual(pasteboard.string(forType: .string), "sentinel")
        XCTAssertFalse(pasteboard.pasteboardItems?.contains {
            $0.types.contains(.fileURL)
        } ?? false)
    }

    func testSharedTextClipboardIgnoresFinderFileDropFallbackText() async throws {
        let fixture = try TemporaryFileFixture(names: ["Report.txt"])
        defer { fixture.remove() }
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        let service = SystemClipboardService(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        let recorder = ClipboardObservationRecorder()
        let stream = service.events()
        let observationTask = Task { @MainActor in
            for await value in stream {
                await recorder.append(value)
            }
        }
        defer { observationTask.cancel() }

        let item = NSPasteboardItem()
        item.setString(fixture.urls[0].absoluteString, forType: .fileURL)
        item.setString(fixture.urls[0].path, forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        service.pollNowForTesting()
        try await Task.sleep(for: .milliseconds(50))
        let observationCount = await recorder.count
        XCTAssertEqual(observationCount, 0)
    }

    func testSourceProviderRenamesDuplicateFinderItemsDeterministically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniSpace-Finder-Duplicates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDirectory = root.appendingPathComponent("First", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("Report.txt")
        let second = secondDirectory.appendingPathComponent("Report.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let provider = SystemFileSourceProvider(
            rootURL: root.appendingPathComponent("Metadata", isDirectory: true)
        )
        let transferID = TransferID()
        let prepared = try await provider.prepare(
            urls: [first, second],
            transferID: transferID,
            workspaceID: WorkspaceID(),
            sourceDeviceID: DeviceID(),
            destinationDeviceID: DeviceID(),
            limits: .default
        )

        XCTAssertEqual(prepared.manifest.entries.map(\.filename), ["Report.txt", "Report 2.txt"])
        XCTAssertEqual(Set(prepared.manifest.entries.map(\.filename)).count, 2)
        await provider.removeOutgoingTransfer(transferID)
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("UniSpaceTests.\(UUID().uuidString)"))
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}

private struct TemporaryFileFixture {
    let root: URL
    let urls: [URL]

    init(names: [String]) throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniSpace-Finder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)

        root = fixtureRoot
        urls = try names.enumerated().map { index, name in
            let url = fixtureRoot.appendingPathComponent(name)
            try Data("payload-\(index)".utf8).write(to: url)
            return url
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor FileSelectionRecorder {
    private var storage: [PasteboardFileSelection] = []

    var count: Int { storage.count }
    var values: [PasteboardFileSelection] { storage }

    func append(_ value: PasteboardFileSelection) {
        storage.append(value)
    }
}

private actor ClipboardObservationRecorder {
    private var storage: [ClipboardObservation] = []

    var count: Int { storage.count }

    func append(_ value: ClipboardObservation) {
        storage.append(value)
    }
}
