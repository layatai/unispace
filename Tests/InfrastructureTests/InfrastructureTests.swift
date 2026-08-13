import XCTest
@testable import UniSpaceInfrastructure
import Network
import UniSpaceApplication
import UniSpaceDomain

final class InfrastructureTests: XCTestCase {
    func testApplicationDeclaresEveryBonjourServiceAndLocalNetworkPurpose() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(
            Set(try XCTUnwrap(plist["NSBonjourServices"] as? [String])),
            [NetworkPeerTransport.serviceType, PairingNetworkService.serviceType]
        )
        XCTAssertFalse(try XCTUnwrap(plist["NSLocalNetworkUsageDescription"] as? String).isEmpty)
    }

    func testPairingSessionsDeriveSameCodeAndTransferWorkspaceKey() throws {
        let host = PairingCryptoSession()
        let joiner = PairingCryptoSession()

        XCTAssertEqual(
            try host.shortAuthenticationCode(peerOffer: joiner.offer),
            try joiner.shortAuthenticationCode(peerOffer: host.offer)
        )

        let workspaceKey = PairingCryptoSession.randomData(count: 32)
        let sealed = try host.sealWorkspaceKey(workspaceKey, peerOffer: joiner.offer)
        XCTAssertEqual(try joiner.openWorkspaceKey(sealed, peerOffer: host.offer), workspaceKey)
    }

    func testPairingRejectsInvalidPeerPublicKey() throws {
        let host = PairingCryptoSession()
        XCTAssertThrowsError(
            try host.shortAuthenticationCode(peerOffer: PairingOffer(publicKey: Data([1, 2, 3]), nonce: Data(repeating: 0, count: 32)))
        )
    }

    func testWorkspaceStoreRoundTripsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileWorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let local = DeviceID()
        let snapshot = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "Test",
            localDeviceID: local,
            devices: [.init(id: local, name: "Local")]
        )
        try store.save(snapshot)
        XCTAssertEqual(try store.load(), snapshot)
    }

    @MainActor
    func testDisplayCatalogReturnsStableUniqueIdentifiers() {
        let displays = SystemDisplayCatalog().currentDisplays(for: DeviceID())
        XCTAssertFalse(displays.isEmpty)
        XCTAssertEqual(Set(displays.map(\.id)).count, displays.count)
    }

    func testAuthenticatedEncryptedChannelCompletesLoopbackHandshakeAndTransfersFrame() throws {
        let workspaceID = WorkspaceID()
        let key = PairingCryptoSession.randomData(count: 32)
        let serverDevice = DeviceID()
        let clientDevice = DeviceID()
        let listener = try NWListener(using: NetworkPeerTransport.makeParameters(), on: .any)
        let listenerReady = expectation(description: "listener ready")
        let serverAuthenticated = expectation(description: "server authenticated client")
        let clientAuthenticated = expectation(description: "client authenticated server")
        let frameReceived = expectation(description: "encrypted frame received")
        let queue = DispatchQueue(label: "UniSpaceInfrastructureTests.SecureChannel")
        let retainer = SecureConnectionRetainer()
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            let secure = SecurePeerConnection(
                connection: connection,
                localDeviceID: serverDevice,
                workspaceID: workspaceID,
                workspaceKey: key,
                expectedDeviceID: clientDevice
            )
            secure.authenticatedHandler = { id in
                XCTAssertEqual(id, clientDevice)
                serverAuthenticated.fulfill()
            }
            secure.frameHandler = { kind, payload in
                XCTAssertEqual(kind, .controlJSON)
                do {
                    _ = try WireFrameCodec.decodeControl(payload)
                } catch {
                    XCTFail("Unable to decode encrypted control frame: \(error)")
                }
                frameReceived.fulfill()
            }
            retainer.connection = secure
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        wait(for: [listenerReady], timeout: 3)
        let port = try XCTUnwrap(listener.port)
        let rawClient = NWConnection(
            host: "127.0.0.1",
            port: port,
            using: NetworkPeerTransport.makeParameters()
        )
        let client = SecurePeerConnection(
            connection: rawClient,
            localDeviceID: clientDevice,
            workspaceID: workspaceID,
            workspaceKey: key,
            expectedDeviceID: serverDevice
        )
        client.authenticatedHandler = { id in
            XCTAssertEqual(id, serverDevice)
            clientAuthenticated.fulfill()
        }
        rawClient.start(queue: queue)
        wait(for: [serverAuthenticated, clientAuthenticated], timeout: 5)
        let envelope = ControlEnvelope(message: .hello(.init(id: clientDevice, name: "Client")))
        client.send(try WireFrameCodec.encodeControl(envelope), completion: nil)
        wait(for: [frameReceived], timeout: 3)
        client.cancel()
        listener.cancel()
    }
}

private final class SecureConnectionRetainer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SecurePeerConnection?
    var connection: SecurePeerConnection? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
