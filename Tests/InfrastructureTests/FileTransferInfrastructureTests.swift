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
        let firstOffset = try await store.write(TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: 0,
            data: Data(payload.prefix(5))
        ), limits: .default)
        XCTAssertEqual(firstOffset, 5)
        let finalOffset = try await store.write(TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: 5,
            data: Data(payload.dropFirst(5))
        ), limits: .default)
        XCTAssertEqual(finalOffset, UInt64(payload.count))

        let staged = try await store.finalizeEntry(
            transferID: manifest.transferID,
            entryID: entry.id
        )
        XCTAssertEqual(try Data(contentsOf: staged), payload)
        let finalized = try await store.finalizeTransfer(manifest.transferID)
        XCTAssertEqual(finalized, [staged])

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
        XCTAssertEqual(
            recovered.first?.offsets,
            [TransferEntryOffset(entryID: entry.id, offset: 3)]
        )
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

        let threw = await throwsAsync {
            _ = try await store.finalizeEntry(
                transferID: manifest.transferID,
                entryID: entry.id
            )
        }
        XCTAssertTrue(threw)
        await store.cancel(manifest.transferID)
        let exists = FileManager.default.fileExists(
            atPath: root.appendingPathComponent(manifest.transferID.rawValue.uuidString).path
        )
        XCTAssertFalse(exists)
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
        let chunk = try await provider.readChunk(
            transferID: transferID,
            entryID: entry.id,
            offset: 0,
            maximumLength: 16
        )
        XCTAssertEqual(chunk, Data("first".utf8))

        try Data("changed".utf8).write(to: url, options: [.atomic])
        let threw = await throwsAsync {
            _ = try await provider.readChunk(
                transferID: transferID,
                entryID: entry.id,
                offset: 0,
                maximumLength: 16
            )
        }
        XCTAssertTrue(threw)
        await provider.removeOutgoingTransfer(transferID)
    }

    @MainActor
    func testPasteboardPublishesFinderURLObjectsAndDoesNotReemitThem() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let received = directory.appendingPathComponent("received.txt")
        try Data("received".utf8).write(to: received)
        let adapter = SystemFilePasteboard(
            pasteboard: pasteboard,
            pollingInterval: .milliseconds(20)
        )
        let stream = adapter.events()
        let transferID = TransferID()
        adapter.publishFiles(
            [received],
            transferID: transferID
        )

        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.string(forType: SystemFilePasteboard.originType),
            transferID.rawValue.uuidString
        )
        let finderObjects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        XCTAssertEqual(
            finderObjects.compactMap { ($0 as? NSURL).map { $0 as URL } },
            [received]
        )
        let result = await firstValue(from: stream, timeout: .milliseconds(100))
        XCTAssertNil(result)
    }

    @MainActor
    func testFinderCopyOfSameFileIsObservedEveryTime() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Repeated.txt")
        try Data("repeat".utf8).write(to: source)
        let adapter = SystemFilePasteboard(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        let stream = adapter.events()
        var changeCounts: [Int] = []

        for _ in 0..<3 {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([source as NSURL]))
            adapter.pollNowForTesting()
            let selection = await firstValue(from: stream, timeout: .seconds(1))
            XCTAssertEqual(selection?.urls, [source.standardizedFileURL])
            changeCounts.append(try XCTUnwrap(selection?.changeCount))
        }

        XCTAssertEqual(Set(changeCounts).count, 3)
    }

    @MainActor
    func testInvalidPublicationPreservesExistingClipboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("sentinel", forType: .string))
        let adapter = SystemFilePasteboard(pasteboard: pasteboard)

        XCTAssertThrowsError(try adapter.publishFilesChecked(
            [URL(fileURLWithPath: "/missing/UniSpace.txt")],
            transferID: TransferID()
        )) { error in
            XCTAssertEqual(error as? FilePasteboardPublicationError, .invalidFileSet)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "sentinel")
    }

    @MainActor
    func testSharedPasteboardRoutesTextAndFinderFilesWithoutCrossConsumption() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let clipboard = SystemClipboardService(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        let files = SystemFilePasteboard(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        let clipboardEvents = clipboard.events()
        let fileEvents = files.events()

        let textItem = NSPasteboardItem()
        textItem.setString("shared continuity text", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([textItem]))
        clipboard.pollNowForTesting()
        files.pollNowForTesting()

        let text = await firstValue(from: clipboardEvents, timeout: .seconds(1))
        XCTAssertEqual(text?.representations, [
            ClipboardRepresentation(kind: .plainText, value: "shared continuity text")
        ])

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Finder copy.txt")
        try Data("file payload".utf8).write(to: source)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([source as NSURL]))
        clipboard.pollNowForTesting()
        files.pollNowForTesting()

        let unexpectedText = await firstValue(
            from: clipboardEvents,
            timeout: .milliseconds(100)
        )
        XCTAssertNil(unexpectedText)
        let selection = await firstValue(from: fileEvents, timeout: .seconds(1))
        XCTAssertEqual(selection?.urls, [source.standardizedFileURL])
    }

    func testBonjourServiceNameMeetsDNSServiceLengthLimit() {
        let serviceName = NetworkFileTransferTransport.serviceType
            .split(separator: ".")
            .first
            .map(String.init) ?? ""
        XCTAssertLessThanOrEqual(serviceName.utf8.count, 15)
        XCTAssertEqual(NetworkFileTransferTransport.contentPort.rawValue, 61_340)
    }

    func testContentChannelHelloUsesPortableWindowsUUIDShape() throws {
        let workspaceID = WorkspaceID(
            rawValue: try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        )
        let deviceID = DeviceID(
            rawValue: try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        )
        let nonce = Data(repeating: 0x11, count: 32)
        let proof = Data(repeating: 0x22, count: 32)
        let hello = FileTransferChannelHello(
            version: 1,
            workspaceID: workspaceID,
            deviceID: deviceID,
            nonce: nonce,
            proof: proof
        )

        let encoded = try JSONEncoder().encode(hello)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["workspaceID"] as? String, workspaceID.rawValue.uuidString)
        XCTAssertEqual(object["deviceID"] as? String, deviceID.rawValue.uuidString)
        XCTAssertEqual(object["nonce"] as? String, nonce.base64EncodedString())
        XCTAssertEqual(object["proof"] as? String, proof.base64EncodedString())

        let windowsJSON = Data("""
        {"version":1,"workspaceID":"11111111-2222-3333-4444-555555555555","deviceID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","nonce":"\(nonce.base64EncodedString())","proof":"\(proof.base64EncodedString())"}
        """.utf8)
        let decoded = try JSONDecoder().decode(FileTransferChannelHello.self, from: windowsJSON)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.workspaceID, workspaceID)
        XCTAssertEqual(decoded.deviceID, deviceID)
        XCTAssertEqual(decoded.nonce, nonce)
        XCTAssertEqual(decoded.proof, proof)

        let installedWindowsJSON = Data("""
        {"version":1,"workspaceID":{"rawValue":"11111111-2222-3333-4444-555555555555"},"deviceID":{"rawValue":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"},"nonce":"\(nonce.base64EncodedString())","proof":"\(proof.base64EncodedString())"}
        """.utf8)
        let installedWindowsHello = try JSONDecoder().decode(
            FileTransferChannelHello.self,
            from: installedWindowsJSON
        )
        XCTAssertEqual(installedWindowsHello.version, 1)
        XCTAssertEqual(installedWindowsHello.workspaceID, workspaceID)
        XCTAssertEqual(installedWindowsHello.deviceID, deviceID)
        XCTAssertEqual(installedWindowsHello.nonce, nonce)
        XCTAssertEqual(installedWindowsHello.proof, proof)
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
        try await serverTransport.start(
            localDevice: server,
            workspace: serverWorkspace,
            key: key
        )
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
        let clientConnected = expectation(description: "content client connected")
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
        let clientTask = Task {
            for await event in clientTransport.events() {
                if case let .connected(deviceID) = event, deviceID == server.id {
                    clientConnected.fulfill()
                }
            }
        }
        try await clientTransport.start(
            localDevice: client,
            workspace: clientWorkspace,
            key: key
        )
        clientTransport.setDesiredPeer(server.id)
        await fulfillment(of: [connected, clientConnected], timeout: 5)
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
        clientTask.cancel()
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

    private func throwsAsync(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return false
        } catch {
            return true
        }
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
