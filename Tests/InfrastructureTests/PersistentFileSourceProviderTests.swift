import Foundation
import XCTest
@testable import UniSpaceInfrastructure
import UniSpaceDomain

final class PersistentFileSourceProviderTests: XCTestCase {
    func testOutgoingSourceRecoversAfterProviderRelaunch() async throws {
        let metadataRoot = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: metadataRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let sourceURL = sourceRoot.appendingPathComponent("resume.txt")
        let payload = Data("resume after relaunch".utf8)
        try payload.write(to: sourceURL)

        let transferID = TransferID()
        let firstProvider = PersistentSystemFileSourceProvider(rootURL: metadataRoot)
        let prepared = try await firstProvider.prepare(
            urls: [sourceURL],
            transferID: transferID,
            workspaceID: WorkspaceID(),
            sourceDeviceID: DeviceID(),
            destinationDeviceID: DeviceID(),
            limits: .default
        )
        let entry = try XCTUnwrap(prepared.manifest.entries.first)

        let relaunchedProvider = PersistentSystemFileSourceProvider(rootURL: metadataRoot)
        let recovered = try await relaunchedProvider.recoverOutgoingTransfers(limits: .default)
        XCTAssertEqual(recovered.map(\.manifest.transferID), [transferID])
        let data = try await relaunchedProvider.readChunk(
            transferID: transferID,
            entryID: entry.id,
            offset: 0,
            maximumLength: 64
        )
        XCTAssertEqual(data, payload)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
