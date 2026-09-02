import AppKit
import Foundation
import Network
import XCTest
@testable import UniSpaceInfrastructure
import UniSpaceApplication
import UniSpaceDomain

final class ClipboardInfrastructureTests: XCTestCase {
    func testEncryptedClipboardTransportConnectsAndTransfersUpdate() async throws {
        let workspaceID = WorkspaceID()
        let key = PairingCryptoSession.randomData(count: 32)
        let server = DeviceDescriptor(
            id: DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            name: "Server"
        )
        let client = DeviceDescriptor(
            id: DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            name: "Client"
        )
        let serverWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Clipboard",
            localDeviceID: server.id,
            devices: [server, client]
        )
        let serverTransport = NetworkClipboardTransport(
            listenPort: .any,
            directPort: .any,
            enableBonjour: false
        )
        try await serverTransport.start(localDevice: server, workspace: serverWorkspace, key: key)
        serverTransport.setDesiredPeer(client.id)
        let port = try await waitForPort(serverTransport)

        let routedServer = DeviceDescriptor(
            id: server.id,
            name: server.name,
            peerAddresses: [try PeerAddress("127.0.0.1")]
        )
        let clientWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Clipboard",
            localDeviceID: client.id,
            devices: [routedServer, client]
        )
        let clientTransport = NetworkClipboardTransport(
            listenPort: .any,
            directPort: port,
            enableBonjour: false
        )
        let connected = expectation(description: "clipboard channel connected")
        let clientConnected = expectation(description: "clipboard client connected")
        let received = expectation(description: "clipboard update received")
        let serverTask = Task {
            for await event in serverTransport.events() {
                switch event {
                case let .connected(deviceID) where deviceID == client.id:
                    connected.fulfill()
                case let .update(deviceID, envelope) where deviceID == client.id:
                    if envelope.payload.plainText == "hello" { received.fulfill() }
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

        try await clientTransport.start(localDevice: client, workspace: clientWorkspace, key: key)
        clientTransport.setDesiredPeer(server.id)
        await fulfillment(of: [connected, clientConnected], timeout: 5)
        let representations = [ClipboardRepresentation(kind: .plainText, value: "hello")]
        try await clientTransport.send(
            ClipboardEnvelope(
                workspaceID: workspaceID,
                senderDeviceID: client.id,
                payload: ClipboardPayload(
                    originDeviceID: client.id,
                    revision: 1,
                    timestamp: Date(timeIntervalSince1970: 10),
                    contentHash: ClipboardSyncEngine.contentHash(for: representations),
                    representations: representations
                )
            ),
            to: server.id
        )
        await fulfillment(of: [received], timeout: 3)

        do {
            try await serverTransport.send(
                ClipboardEnvelope(
                    workspaceID: workspaceID,
                    senderDeviceID: server.id,
                    payload: ClipboardPayload(
                        originDeviceID: server.id,
                        revision: 1,
                        contentHash: ClipboardSyncEngine.contentHash(for: representations),
                        representations: representations
                    )
                ),
                to: DeviceID()
            )
            XCTFail("Expected unavailable peer")
        } catch let error as NetworkClipboardError {
            guard case .peerUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }

        await clientTransport.stop()
        await serverTransport.stop()
        serverTask.cancel()
        clientTask.cancel()
        XCTAssertNil(clientTransport.activePort)
    }

    func testClipboardTransportRejectsInvalidConfigurationAndExposesConstants() async {
        let local = DeviceDescriptor(id: DeviceID(), name: "Local")
        let workspace = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "Invalid",
            localDeviceID: local.id,
            devices: [local]
        )
        let transport = NetworkClipboardTransport(
            listenPort: .any,
            directPort: .any,
            enableBonjour: false
        )
        do {
            try await transport.start(localDevice: local, workspace: workspace, key: Data())
            XCTFail("Expected invalid configuration")
        } catch let error as NetworkClipboardError {
            XCTAssertEqual(error, .invalidConfiguration)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(NetworkClipboardTransport.clipboardPort.rawValue, 61_342)
        XCTAssertLessThanOrEqual(
            NetworkClipboardTransport.serviceType.split(separator: ".").first?.utf8.count ?? .max,
            15
        )
        XCTAssertEqual(NetworkClipboardError.authenticationFailed, .authenticationFailed)
        XCTAssertEqual(NetworkClipboardError.replayedFrame, .replayedFrame)
        XCTAssertEqual(NetworkClipboardError.malformedPacket, .malformedPacket)
        XCTAssertEqual(NetworkClipboardError.sendFailed("x"), .sendFailed("x"))
    }

    func testClipboardListenerRetriesAfterPortBecomesAvailable() async throws {
        let blocker = try NWListener(using: .tcp, on: .any)
        blocker.newConnectionHandler = { $0.cancel() }
        blocker.start(queue: DispatchQueue(label: "clipboard-port-blocker"))
        let port = try await waitForPort(blocker)
        defer { blocker.cancel() }

        let local = DeviceDescriptor(id: DeviceID(), name: "Local")
        let workspace = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "Clipboard",
            localDeviceID: local.id,
            devices: [local]
        )
        let transport = NetworkClipboardTransport(
            listenPort: port,
            directPort: port,
            enableBonjour: false,
            listenerRetryDelays: [0.02]
        )
        try await transport.start(
            localDevice: local,
            workspace: workspace,
            key: Data(repeating: 1, count: 32)
        )
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(transport.activePort)

        blocker.cancel()
        let recoveredPort = try await waitForPort(transport)
        XCTAssertEqual(recoveredPort, port)
        await transport.stop()
    }

    @MainActor
    func testSystemClipboardObservesPortableValuesAndSuppressesAppliedPayloads() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let service = SystemClipboardService(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        let stream = service.events()
        _ = service.events()

        let item = NSPasteboardItem()
        item.setString("https://example.com/path", forType: .URL)
        item.setString("Example", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        service.pollNowForTesting()
        let first = await firstValue(from: stream)
        XCTAssertEqual(first?.representations, [
            ClipboardRepresentation(kind: .plainText, value: "Example"),
            ClipboardRepresentation(kind: .url, value: "https://example.com/path"),
        ])

        let representations = [
            ClipboardRepresentation(kind: .plainText, value: "Remote"),
            ClipboardRepresentation(kind: .url, value: "https://example.com/remote"),
        ]
        let payload = ClipboardPayload(
            originDeviceID: DeviceID(),
            revision: 1,
            contentHash: ClipboardSyncEngine.contentHash(for: representations),
            representations: representations
        )
        service.apply(payload)
        XCTAssertEqual(pasteboard.string(forType: .string), "Remote")
        XCTAssertEqual(pasteboard.string(forType: .URL), "https://example.com/remote")
        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.string(forType: SystemClipboardService.originType),
            payload.payloadID.rawValue.uuidString
        )
        service.pollNowForTesting()

        let textURL = NSPasteboardItem()
        textURL.setString("https://example.com/text", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([textURL]))
        service.pollNowForTesting()
        let second = await firstValue(from: stream)
        XCTAssertEqual(second?.representations.map(\.kind), [.plainText, .url])

        let fileURL = NSPasteboardItem()
        fileURL.setString("file:///tmp/private", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL]))
        service.pollNowForTesting()
        let third = await firstValue(from: stream)
        XCTAssertEqual(third?.representations.map(\.kind), [.plainText])

        let finderFile = NSPasteboardItem()
        let sourceFile = URL(fileURLWithPath: #filePath)
        finderFile.setString(sourceFile.absoluteString, forType: .fileURL)
        finderFile.setString(sourceFile.lastPathComponent, forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([finderFile]))
        service.pollNowForTesting()
        let ignoredFile = await firstValue(from: stream, timeout: .milliseconds(100))
        XCTAssertNil(ignoredFile)

        service.apply(ClipboardPayload(
            originDeviceID: DeviceID(),
            revision: 2,
            contentHash: Data(repeating: 0, count: 32),
            representations: []
        ))
        service.stop()
    }

    @MainActor
    func testSystemClipboardObservesThreeIdenticalLocalCopies() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let service = SystemClipboardService(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        let stream = service.events()
        var changeCounts = Set<Int>()
        let expected = [
            ClipboardRepresentation(kind: .plainText, value: "copy repeatedly")
        ]

        for copyNumber in 1...3 {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString("copy repeatedly", forType: .string))
            service.pollNowForTesting()

            let nextObservation = await firstValue(from: stream)
            let observation = try XCTUnwrap(nextObservation)
            XCTAssertEqual(
                observation.representations,
                expected,
                "Copy \(copyNumber) should produce the same portable content"
            )
            XCTAssertTrue(
                changeCounts.insert(observation.changeCount).inserted,
                "Copy \(copyNumber) should have a distinct pasteboard change count"
            )
        }

        service.stop()
    }

    @MainActor
    func testSystemClipboardAppliesThreeIdenticalRemoteUpdatesWithoutEcho() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let service = SystemClipboardService(
            pasteboard: pasteboard,
            pollingInterval: .seconds(60)
        )
        let stream = service.events()
        let representations = [
            ClipboardRepresentation(kind: .plainText, value: "paste repeatedly")
        ]
        var changeCounts = Set<Int>()

        for revision in UInt64(1)...3 {
            let payload = ClipboardPayload(
                originDeviceID: DeviceID(),
                revision: revision,
                contentHash: ClipboardSyncEngine.contentHash(for: representations),
                representations: representations
            )
            service.apply(payload)

            XCTAssertEqual(pasteboard.string(forType: .string), "paste repeatedly")
            XCTAssertEqual(
                pasteboard.pasteboardItems?.first?.string(
                    forType: SystemClipboardService.originType
                ),
                payload.payloadID.rawValue.uuidString
            )
            XCTAssertTrue(
                changeCounts.insert(pasteboard.changeCount).inserted,
                "Remote update \(revision) should republish identical text"
            )

            service.pollNowForTesting()
            let echoed = await firstValue(from: stream, timeout: .milliseconds(100))
            XCTAssertNil(echoed, "Remote update \(revision) must not be sent back")
        }

        service.stop()
    }

    private func waitForPort(_ transport: NetworkClipboardTransport) async throws -> NWEndpoint.Port {
        for _ in 0..<200 {
            if let port = transport.activePort { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NetworkClipboardError.invalidConfiguration
    }

    private func waitForPort(_ listener: NWListener) async throws -> NWEndpoint.Port {
        for _ in 0..<200 {
            if let port = listener.port, port != .any { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NetworkClipboardError.invalidConfiguration
    }

    @MainActor
    private func firstValue<T: Sendable>(
        from stream: AsyncStream<T>,
        timeout: Duration = .seconds(1)
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
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }
}
