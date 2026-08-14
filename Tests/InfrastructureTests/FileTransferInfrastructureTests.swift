import AppKit
import CryptoKit
import Foundation
import Network
import XCTest
@testable import UniSpaceInfrastructure
import UniSpaceApplication
import UniSpaceDomain

final class FileTransferInfrastructureTests: XCTestCase {
    func testSandboxStoreStreamsVerifiesAndRecoversCompletedFiles() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("hello encrypted world".utf8)
        let entry = TransferManifestEntry(
            filename: "hello.txt",
            byteCount: UInt64(payload.count),
            sha256: Data(SHA256.hash(data: payload))
        )
        let manifest = makeManifest(entry: entry)
        let store = SandboxTransferStore(rootURL: root)

        try await store.prepareIncoming(manifest: manifest, limits: .default)
        let first = payload.prefix(5)
        XCTAssertEqual(try await store.write(TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: 0,
            data: Data(first)
        ), limits: .default), 5)
        XCTAssertEqual(try await store.write(TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: 5,
            data: Data(payload.dropFirst(5))
        ), limits: .default), UInt64(payload.count))

        let staged = try await store.finalizeEntry(
            transferID: manifest.transferID,
            entryID: entry.id
        )
        XCTAssertEqual(try Data(contentsOf: staged), payload)
        XCTAssertEqual(try await store.finalizeTransfer(manifest.transferID), [staged])

        let recovered = try await SandboxTransferStore(rootURL: root)
            .recoverIncomingTransfers(limits: .default)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertTrue(recovered[0].isCompleted)
        XCTAssertEqual(recovered[0].completedURLs, [staged])
    }

    func testRecoveryTruncatesBytesBeyondDurableOffset() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data([1, 2, 3, 4, 5, 6])
        let entry = TransferManifestEntry(
            filename: "partial.bin",
            byteCount: UInt64(payload.count),
            sha256: Data(SHA256.hash(data: payload))
        )
        let manifest = makeManifest(entry: entry)
        let store = SandboxTransferStore(rootURL: root)
        try await store.prepareIncoming(manifest: manifest, limits: .default)
        _ = try await store.write(TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: 0,
            data: Data(payload.prefix(3))
        ), limits: .default)

        let partial = root
            .appendingPathComponent(manifest.transferID.rawValue.uuidString)
            .appendingPathComponent("Partial")
            .appendingPathComponent(entry.id.rawValue.uuidString)
            .appendingPathExtension("partial")
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([99, 99]))
        try handle.close()
        XCTAssertEqual(try fileSize(partial), 5)

        let recovered = try await SandboxTransferStore(rootURL: root)
            .recoverIncomingTransfers(limits: .default)
        XCTAssertEqual(recovered.first?.offsets, [TransferEntryOffset(entryID: entry.id, offset: 3)])
        XCTAssertEqual(try fileSize(partial), 3)
    }

    func testSandboxStoreRejectsHashMismatchAndCleansCancellation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = TransferManifestEntry(
            filename: "bad.bin",
            byteCount: 2,
            sha256: Data(repeating: 0, count: 32)
        )
        let manifest = makeManifest(entry: entry)
        let store = SandboxTransferStore(rootURL: root)
        try await store.prepareIncoming(manifest: manifest, limits: .default)
        _ = try await store.write(TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: 0,
            data: Data([1, 2])
        ), limits: .default)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.finalizeEntry(
                transferID: manifest.transferID,
                entryID: entry.id
            )
        }
        await store.cancel(manifest.transferID)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(manifest.transferID.rawValue.uuidString).path
        ))
    }

    func testFileSourceProviderStreamsAndDetectsSourceMutation() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let url = sourceRoot.appendingPathComponent("source.txt")
        try Data("first".utf8).write(to: url)
        let provider = SystemFileSourceProvider(rootURL: root)
        let transferID = TransferID()
        let prepared = try await provider.prepare(
            urls: [url],
            transferID: transferID,
            workspaceID: WorkspaceID(),
            sourceDeviceID: DeviceID(),
            destinationDeviceID: DeviceID(),
            limits: .default
        )
        let entry = try XCTUnwrap(prepared.manifest.entries.first)
        XCTAssertEqual(try await provider.readChunk(
            transferID: transferID,
            entryID: entry.id,
            offset: 0,
            maximumLength: 16
        ), Data("first".utf8))

        try Data("changed".utf8).write(to: url, options: [.atomic])
        await XCTAssertThrowsErrorAsync {
            _ = try await provider.readChunk(
                transferID: transferID,
                entryID: entry.id,
                offset: 0,
                maximumLength: 16
            )
        }
        await provider.removeOutgoingTransfer(transferID)
    }

    @MainActor
    func testPasteboardMarksReceivedFilesAndDoesNotReemitThem() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let adapter = SystemFilePasteboard(
            pasteboard: pasteboard,
            pollingInterval: .milliseconds(20)
        )
        let stream = adapter.events()
        let transferID = TransferID()
        let url = URL(fileURLWithPath: "/tmp/received.txt")
        adapter.publishFiles([url], transferID: transferID)

        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.string(forType: SystemFilePasteboard.originType),
            transferID.rawValue.uuidString
        )
        let result = await firstValue(from: stream, timeout: .milliseconds(100))
        XCTAssertNil(result)
    }

    func testEncryptedContentTransportCompletesLoopbackAndTransfersEnvelope() async throws {
        let workspaceID = WorkspaceID()
        let key = PairingCryptoSession.randomData(count: 32)
        let server = DeviceDescriptor(id: DeviceID(), name: "Server")
        let client = DeviceDescriptor(id: DeviceID(), name: "Client")
        let serverWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Loopback",
            localDeviceID: server.id,
            devices: [server, client]
        )
        let serverTransport = NetworkFileTransferTransport(
            listenPort: .any,
            directPort: .any,
            enableBonjour: false
        )
        try await serverTransport.start(localDevice: server, workspace: serverWorkspace, key: key)
        let port = try await waitForPort(serverTransport)

        let routedServer = DeviceDescriptor(
            id: server.id,
            name: server.name,
            peerAddresses: [try PeerAddress("127.0.0.1")]
        )
        let clientWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Loopback",
            localDeviceID: client.id,
            devices: [routedServer, client]
        )
        let clientTransport = NetworkFileTransferTransport(
            listenPort: .any,
            directPort: port,
            enableBonjour: false
        )
        let connected = expectation(description: "content channel connected")
        let received = expectation(description: "encrypted transfer envelope received")
        let serverTask = Task {
            for await event in serverTransport.events() {
                switch event {
                case let .connected(deviceID) where deviceID == client.id:
                    connected.fulfill()
                case let .message(deviceID, envelope) where deviceID == client.id:
                    if case .resumeQuery = envelope.message { received.fulfill() }
                default:
                    break
                }
            }
        }
        try await clientTransport.start(localDevice: client, workspace: clientWorkspace, key: key)
        await fulfillment(of: [connected], timeout: 5)
        try await clientTransport.send(
            FileTransferEnvelope(
                workspaceID: workspaceID,
                senderDeviceID: client.id,
                message: .resumeQuery(TransferResumeQuery(transferID: TransferID()))
            ),
            to: server.id
        )
        await fulfillment(of: [received], timeout: 3)
        await clientTransport.stop()
        await serverTransport.stop()
        serverTask.cancel()
    }

    private func makeManifest(entry: TransferManifestEntry) -> TransferManifest {
        TransferManifest(
            workspaceID: WorkspaceID(),
            sourceDeviceID: DeviceID(),
            destinationDeviceID: DeviceID(),
            entries: [entry]
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return value?.uint64Value ?? 0
    }

    private func waitForPort(_ transport: NetworkFileTransferTransport) async throws -> NWEndpoint.Port {
        for _ in 0..<200 {
            if let port = transport.activePort { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NetworkFileTransferError.notStarted
    }

    @MainActor
    private func firstValue<T: Sendable>(
        from stream: AsyncStream<T>,
        timeout: Duration
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: @escaping () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
