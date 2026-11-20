import CryptoKit
import Foundation
import Testing
import UniSpaceApplication
import UniSpaceDomain
@testable import UniSpaceInfrastructure

struct LocalClipboardSelectionTests {
    @Test func sparseHugeFileMetadataDoesNotReadContentsAndRangesStay64Bit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniSpace-lazy-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("huge.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try FileHandle(forWritingTo: url)
        let position: UInt64 = (1 << 32) + 7
        try writer.truncate(atOffset: position + 3)
        try writer.seek(toOffset: position)
        try writer.write(contentsOf: Data([1, 2, 3])); try writer.close()
        let source = LocalClipboardSelectionSource()
        let selection = try await source.describe(urls: [url], epoch: UUID(), generation: 1)
        #expect(selection.files[0].size == position + 3)
        let reader = try await source.open(selectionID: selection.id, file: selection.files[0])
        #expect(try await reader.read(offset: position, length: 3) == Data([1, 2, 3]))
        await reader.close()
        await source.releaseSelection(selection.id)
    }
    @Test func mutationAndSymlinksAreRejectedAndDigestRunsAfterOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniSpace-lazy-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("data.txt")
        let bytes = Data("verified fixture".utf8)
        try bytes.write(to: url)
        let source = LocalClipboardSelectionSource()
        let selection = try await source.describe(urls: [url], epoch: UUID(), generation: 1)
        let reader = try await source.open(selectionID: selection.id, file: selection.files[0])
        #expect(try await reader.digest() == Data(SHA256.hash(data: bytes)))
        try Data("changed".utf8).write(to: url)
        await #expect(throws: ClipboardStreamFailure.changed) { try await reader.read(offset: 0, length: 1) }
        await reader.close()
        let symlink = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: url)
        await #expect(throws: ClipboardStreamFailure.unsupported) { try await source.describe(urls: [symlink], epoch: UUID(), generation: 2) }
        await source.releaseSelection(selection.id)
    }
    @Test func describeRejectsInvalidInputsAndDeduplicatesNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniSpace-lazy-test-\(UUID())")
        let first = root.appendingPathComponent("a"), second = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = first.appendingPathComponent("Report.txt"), two = second.appendingPathComponent("report.txt")
        try Data("one".utf8).write(to: one); try Data("two".utf8).write(to: two)
        let source = LocalClipboardSelectionSource()
        await #expect(throws: ClipboardStreamFailure.invalidRequest) { try await source.describe(urls: [], epoch: UUID(), generation: 1) }
        await #expect(throws: ClipboardStreamFailure.invalidRequest) {
            try await source.describe(urls: [URL(string: "https://example.com/file.txt")!], epoch: UUID(), generation: 1)
        }
        await #expect(throws: ClipboardStreamFailure.unavailable) {
            try await source.describe(urls: [root.appendingPathComponent("missing.txt")], epoch: UUID(), generation: 1)
        }
        await #expect(throws: ClipboardStreamFailure.unsupported) { try await source.describe(urls: [first], epoch: UUID(), generation: 1) }
        let selection = try await source.describe(urls: [one, two], epoch: UUID(), generation: 1)
        #expect(selection.files.map(\.name) == ["Report.txt", "report (2).txt"], "Case-folded name collisions get a numbered suffix")
        #expect(selection.files[0].contentType == "public.plain-text")
        // A file that changed after describe is refused at open.
        try Data("changed".utf8).write(to: two)
        await #expect(throws: ClipboardStreamFailure.changed) { try await source.open(selectionID: selection.id, file: selection.files[1]) }
        // Released or unknown selections never hand out readers.
        await source.releaseSelection(selection.id)
        await #expect(throws: ClipboardStreamFailure.unavailable) { try await source.open(selectionID: selection.id, file: selection.files[0]) }
        await source.releaseSelection(selection.id)
    }
    @Test func readerRejectsBadLengthsAndAllUseAfterClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniSpace-lazy-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("data.bin")
        try Data(repeating: 7, count: 32).write(to: url)
        let source = LocalClipboardSelectionSource()
        let selection = try await source.describe(urls: [url], epoch: UUID(), generation: 1)
        let reader = try await source.open(selectionID: selection.id, file: selection.files[0])
        await #expect(throws: ClipboardStreamFailure.invalidRequest) { try await reader.read(offset: 0, length: -1) }
        await #expect(throws: ClipboardStreamFailure.invalidRequest) {
            try await reader.read(offset: 0, length: ClipboardStreamLimits.default.maximumReadBytes + 1)
        }
        #expect(try await reader.read(offset: 30, length: 8) == Data([7, 7]), "Reads past EOF are truncated")
        await reader.close()
        await reader.close()
        await #expect(throws: ClipboardStreamFailure.cancelled) { try await reader.read(offset: 0, length: 1) }
        await #expect(throws: ClipboardStreamFailure.cancelled) { try await reader.digest() }
        await source.releaseSelection(selection.id)
    }
}
