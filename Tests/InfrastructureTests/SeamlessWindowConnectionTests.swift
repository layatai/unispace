import Foundation
import Network
import XCTest
import UniSpaceApplication
import UniSpaceDomain
@testable import UniSpaceInfrastructure

@MainActor
final class SeamlessWindowConnectionTests: XCTestCase {
    func testEncryptedLoopbackDeliversControlAndEnforcesPayloadBound() async throws {
        let pair = try ConnectionPair()
        defer { pair.close() }
        let serverReady = expectation(description: "server authenticated")
        let clientReady = expectation(description: "client authenticated")
        let delivered = expectation(description: "control delivered")
        let message = SeamlessWindowMessage.heartbeat(UUID())
        pair.serverReady = { _ in serverReady.fulfill() }
        pair.serverPacket = { peer, data in
            XCTAssertEqual(peer, pair.clientID)
            XCTAssertEqual(try? SeamlessWindowCodec.decode(data), message)
            delivered.fulfill()
        }
        try await pair.start(clientReady: { _ in clientReady.fulfill() })
        let ready = await XCTWaiter.fulfillment(of: [serverReady, clientReady], timeout: 5)
        XCTAssertEqual(ready, .completed)
        XCTAssertTrue(pair.client?.send(try SeamlessWindowCodec.encode(message)) == true)
        XCTAssertFalse(pair.client?.send(Data(count: SeamlessWindowLimits.maximumControlBytes + 1)) == true)
        let result = await XCTWaiter.fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual(result, .completed)
    }

    func testWrongWorkspaceKeyClosesWithoutAuthenticating() async throws {
        let pair = try ConnectionPair()
        defer { pair.close() }
        let closed = expectation(description: "wrong-key connection rejected")
        pair.serverClosed = { closed.fulfill() }
        pair.serverReady = { _ in XCTFail("Wrong key must not authenticate") }
        try await pair.start(clientKey: Data(repeating: 2, count: 32))
        let result = await XCTWaiter.fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(result, .completed)
        XCTAssertNil(pair.server?.peer)
    }

    func testVideoHelloCannotAuthenticateOnControlLane() async throws {
        let pair = try ConnectionPair()
        defer { pair.close() }
        let closed = expectation(description: "lane mismatch rejected")
        pair.serverClosed = { closed.fulfill() }
        pair.serverReady = { _ in XCTFail("Lane mismatch must not authenticate") }
        try await pair.start(clientLane: .video)
        let result = await XCTWaiter.fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(result, .completed)
        XCTAssertNil(pair.server?.peer)
    }
}

@MainActor
private final class ConnectionPair {
    let serverID = DeviceID()
    let clientID = DeviceID()
    let workspace = WorkspaceID()
    let key = Data(repeating: 1, count: 32)
    let listener: NWListener
    var client: SeamlessWindowConnection?
    var server: SeamlessWindowConnection?
    var serverReady: ((DeviceID) -> Void)?
    var serverPacket: ((DeviceID, Data) -> Void)?
    var serverClosed: (() -> Void)?

    init() throws { listener = try NWListener(using: SeamlessWindowConnection.parameters(), on: .any) }

    func start(clientKey: Data? = nil, clientLane: SeamlessWindowConnection.Lane = .control,
               clientReady: ((DeviceID) -> Void)? = nil) async throws {
        let listening = XCTestExpectation(description: "listener ready")
        listener.stateUpdateHandler = { state in if case .ready = state { listening.fulfill() } }
        listener.newConnectionHandler = { [weak self] network in
            Task { @MainActor [weak self] in
                guard let self else { network.cancel(); return }
                do {
                    let server = try SeamlessWindowConnection(connection: network, lane: .control, workspace: self.workspace,
                        local: self.serverID, allowed: [self.clientID], expected: self.clientID, key: self.key)
                    self.server = server
                    server.onReady = self.serverReady; server.onPacket = self.serverPacket; server.onClosed = self.serverClosed
                    server.start()
                } catch { XCTFail("Could not create server: \(error)"); network.cancel() }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        let result = await XCTWaiter.fulfillment(of: [listening], timeout: 3)
        XCTAssertEqual(result, .completed)
        let port = try XCTUnwrap(listener.port)
        let network = NWConnection(host: "127.0.0.1", port: port, using: SeamlessWindowConnection.parameters())
        let client = try SeamlessWindowConnection(connection: network, lane: clientLane, workspace: workspace,
            local: clientID, allowed: [serverID], expected: serverID, key: clientKey ?? key)
        self.client = client; client.onReady = clientReady
        client.start()
    }

    func close() {
        listener.cancel()
        client?.onClosed = nil; server?.onClosed = nil
        client?.close(); server?.close()
        client = nil; server = nil
    }
}
