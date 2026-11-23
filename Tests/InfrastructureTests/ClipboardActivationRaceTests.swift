import Foundation
import Network
import XCTest
@testable import UniSpaceInfrastructure
import UniSpaceApplication
import UniSpaceDomain

/// Reproduces the live Mac ↔ Windows activation race: the Windows receiver
/// (lower device ID, so it owns the dial) connects to the Mac's clipboard
/// listener as soon as it learns it is the active control target, which can be
/// before the Mac's own continuity context has set the clipboard desired peer.
final class ClipboardActivationRaceTests: XCTestCase {
    private let workspaceID = WorkspaceID()
    private let key = PairingCryptoSession.randomData(count: 32)
    private static let mac = DeviceDescriptor(
        id: DeviceID(rawValue: UUID(uuidString: "CB9B366F-0000-0000-0000-000000000002")!),
        name: "Mac"
    )
    private static let peer = DeviceDescriptor(
        id: DeviceID(rawValue: UUID(uuidString: "35DC3437-0000-0000-0000-000000000001")!),
        name: "Peer"
    )
    private var mac: DeviceDescriptor { Self.mac }
    private var peer: DeviceDescriptor { Self.peer }

    func testInboundPeerThatAuthenticatesBeforeDesiredPeerIsUpdatedIsKept() async throws {
        let macTransport = try await startMac(desiredPeer: nil)
        let macEvents = EventRecorder(macTransport.events())
        let peerTransport = try await startPeer(dialing: macTransport)
        let peerEvents = EventRecorder(peerTransport.events())

        let peerConnected = await peerEvents.waitFor { $0 == .connected(Self.mac.id) }
        XCTAssertTrue(peerConnected, "The peer should authenticate the Mac's hello")
        // Activation reaches the Mac's clipboard routing a little later.
        try await Task.sleep(for: .milliseconds(150))
        macTransport.setDesiredPeer(peer.id)

        let macConnected = await macEvents.waitFor { $0 == .connected(Self.peer.id) }
        XCTAssertTrue(macConnected)
        try await macTransport.send(envelope(from: mac, text: "mac to peer"), to: peer.id)
        let received = await peerEvents.waitFor {
            if case let .update(_, envelope) = $0 { return envelope.payload.plainText == "mac to peer" }
            return false
        }
        XCTAssertTrue(received)
        let peerDisconnects = await peerEvents.count { $0 == .disconnected(Self.mac.id) }
        XCTAssertEqual(peerDisconnects, 0, "The Mac must not close the first authenticated connection")

        await peerTransport.stop()
        await macTransport.stop()
    }

    func testParkedInboundPeerIsClosedWhenItNeverBecomesTheDesiredPeer() async throws {
        let macTransport = try await startMac(desiredPeer: nil, parkingGrace: 0.2)
        let macEvents = EventRecorder(macTransport.events())
        let peerTransport = try await startPeer(dialing: macTransport)
        let peerEvents = EventRecorder(peerTransport.events())

        let closed = await peerEvents.waitFor { $0 == .disconnected(Self.mac.id) }
        XCTAssertTrue(closed)
        let macConnects = await macEvents.count { $0 == .connected(Self.peer.id) }
        XCTAssertEqual(macConnects, 0)

        await peerTransport.stop()
        await macTransport.stop()
    }

    func testNewerInboundConnectionFromSamePeerReplacesStaleOne() async throws {
        let macTransport = try await startMac(desiredPeer: peer.id)
        let macEvents = EventRecorder(macTransport.events())

        let stalePeer = try await startPeer(dialing: macTransport)
        let staleEvents = EventRecorder(stalePeer.events())
        let firstConnected = await macEvents.waitFor { $0 == .connected(Self.peer.id) }
        XCTAssertTrue(firstConnected)
        let staleConnected = await staleEvents.waitFor { $0 == .connected(Self.mac.id) }
        XCTAssertTrue(staleConnected)

        // The peer redials (for example after it lost the old socket without
        // the Mac noticing). The new connection is the one it reads from.
        let freshPeer = try await startPeer(dialing: macTransport)
        let freshEvents = EventRecorder(freshPeer.events())
        let freshConnected = await freshEvents.waitFor { $0 == .connected(Self.mac.id) }
        XCTAssertTrue(freshConnected)
        try await Task.sleep(for: .milliseconds(150))

        try await macTransport.send(envelope(from: mac, text: "to fresh"), to: peer.id)
        let received = await freshEvents.waitFor {
            if case let .update(_, envelope) = $0 { return envelope.payload.plainText == "to fresh" }
            return false
        }
        XCTAssertTrue(received, "The Mac should send on the newest connection")
        let freshDisconnects = await freshEvents.count { $0 == .disconnected(Self.mac.id) }
        XCTAssertEqual(freshDisconnects, 0)

        await stalePeer.stop()
        await freshPeer.stop()
        await macTransport.stop()
    }

    // MARK: - Helpers

    private func startMac(
        desiredPeer: DeviceID?,
        parkingGrace: TimeInterval = 5
    ) async throws -> NetworkClipboardTransport {
        let transport = NetworkClipboardTransport(
            listenPort: .any,
            directPort: .any,
            enableBonjour: false,
            unexpectedPeerGrace: parkingGrace
        )
        try await transport.start(
            localDevice: mac,
            workspace: WorkspaceSnapshot(
                id: workspaceID,
                name: "Clipboard",
                localDeviceID: mac.id,
                devices: [mac, peer]
            ),
            key: key
        )
        if let desiredPeer { transport.setDesiredPeer(desiredPeer) }
        return transport
    }

    private func startPeer(
        dialing macTransport: NetworkClipboardTransport
    ) async throws -> NetworkClipboardTransport {
        var port: NWEndpoint.Port?
        for _ in 0..<200 {
            port = macTransport.activePort
            if port != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let macPort = try XCTUnwrap(port)
        let routedMac = DeviceDescriptor(
            id: mac.id,
            name: mac.name,
            peerAddresses: [try PeerAddress("127.0.0.1")]
        )
        let transport = NetworkClipboardTransport(
            listenPort: .any,
            directPort: macPort,
            enableBonjour: false
        )
        try await transport.start(
            localDevice: peer,
            workspace: WorkspaceSnapshot(
                id: workspaceID,
                name: "Clipboard",
                localDeviceID: peer.id,
                devices: [routedMac, peer]
            ),
            key: key
        )
        transport.setDesiredPeer(mac.id)
        return transport
    }

    private func envelope(from sender: DeviceDescriptor, text: String) -> ClipboardEnvelope {
        let representations = [ClipboardRepresentation(kind: .plainText, value: text)]
        return ClipboardEnvelope(
            workspaceID: workspaceID,
            senderDeviceID: sender.id,
            payload: ClipboardPayload(
                originDeviceID: sender.id,
                revision: 1,
                timestamp: Date(timeIntervalSince1970: 10),
                contentHash: ClipboardSyncEngine.contentHash(for: representations),
                representations: representations
            )
        )
    }
}

private actor EventRecorderStorage {
    var events: [ClipboardTransportEvent] = []
    func append(_ event: ClipboardTransportEvent) { events.append(event) }
}

private final class EventRecorder: @unchecked Sendable {
    private let storage = EventRecorderStorage()
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<ClipboardTransportEvent>) {
        let storage = self.storage
        task = Task {
            for await event in stream { await storage.append(event) }
        }
    }

    deinit { task?.cancel() }

    func waitFor(
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @Sendable (ClipboardTransportEvent) -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await storage.events.contains(where: predicate) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await storage.events.contains(where: predicate)
    }

    func count(_ predicate: @escaping @Sendable (ClipboardTransportEvent) -> Bool) async -> Int {
        await storage.events.filter(predicate).count
    }
}
