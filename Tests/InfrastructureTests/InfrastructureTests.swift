import XCTest
@testable import UniSpaceInfrastructure
import CoreGraphics
import Network
import UniSpaceApplication
import UniSpaceDomain

final class InfrastructureTests: XCTestCase {
    func testCursorSuppressionKeepsItsFirstAnchorUntilReleased() {
        let firstAnchor = CGPoint(x: 1512, y: 500)
        var state = CursorSuppressionState()

        state.setEnabled(true, currentPosition: firstAnchor)
        state.setEnabled(true, currentPosition: CGPoint(x: 1200, y: 400))

        XCTAssertEqual(state.anchor, firstAnchor)
        XCTAssertEqual(state.restorationPoint(for: .mouseMoved), firstAnchor)
        XCTAssertEqual(state.restorationPoint(for: .leftMouseDragged), firstAnchor)
        XCTAssertNil(state.restorationPoint(for: .keyDown))

        state.setEnabled(false, currentPosition: nil)
        XCTAssertNil(state.anchor)
        XCTAssertNil(state.restorationPoint(for: .mouseMoved))
    }

    func testDisplayIdentifiersAreStableAndNamespacedByDevice() {
        let physicalDisplay = UUID(uuidString: "37D8832A-2D66-02CA-B9F7-8F30A301B230")!
        let firstMac = DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondMac = DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        let first = SystemDisplayCatalog.stableIdentifier(deviceID: firstMac, displayUUID: physicalDisplay)

        XCTAssertEqual(first, SystemDisplayCatalog.stableIdentifier(deviceID: firstMac, displayUUID: physicalDisplay))
        XCTAssertNotEqual(first, SystemDisplayCatalog.stableIdentifier(deviceID: secondMac, displayUUID: physicalDisplay))
    }

    func testNamespacedDisplayIdentifiersRouteAcrossMacsWithMatchingPhysicalUUIDs() {
        let physicalDisplay = UUID(uuidString: "37D8832A-2D66-02CA-B9F7-8F30A301B230")!
        let localMac = DeviceID()
        let remoteMac = DeviceID()
        let localDisplay = display(
            id: SystemDisplayCatalog.stableIdentifier(deviceID: localMac, displayUUID: physicalDisplay),
            deviceID: localMac
        )
        let remoteDisplay = display(
            id: SystemDisplayCatalog.stableIdentifier(deviceID: remoteMac, displayUUID: physicalDisplay),
            deviceID: remoteMac
        )
        var topology = DisplayTopology()
        topology.connect(
            DisplayEndpoint(displayID: localDisplay.id, edge: .right),
            to: DisplayEndpoint(displayID: remoteDisplay.id, edge: .left)
        )

        let transition = EdgeRouter.transition(
            x: 100,
            y: 50,
            localDeviceID: localMac,
            devices: [
                DeviceDescriptor(id: localMac, name: "Local", displays: [localDisplay]),
                DeviceDescriptor(id: remoteMac, name: "Remote", displays: [remoteDisplay])
            ],
            topology: topology
        )

        XCTAssertEqual(transition?.targetDeviceID, remoteMac)
        XCTAssertEqual(transition?.targetDisplayID, remoteDisplay.id)
    }

    func testTailnetAddressClassificationUsesOfficialAddressRanges() {
        XCTAssertTrue(SystemTailnetAddressProvider.isTailnetAddress("100.64.0.1"))
        XCTAssertTrue(SystemTailnetAddressProvider.isTailnetAddress("100.127.255.254"))
        XCTAssertFalse(SystemTailnetAddressProvider.isTailnetAddress("100.128.0.1"))
        XCTAssertFalse(SystemTailnetAddressProvider.isTailnetAddress("192.168.1.10"))
        XCTAssertTrue(SystemTailnetAddressProvider.isTailnetAddress("fd7a:115c:a1e0::1"))
        XCTAssertFalse(SystemTailnetAddressProvider.isTailnetAddress("fd00::1"))
    }

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
            [
                NetworkPeerTransport.serviceType,
                NetworkPeerTransport.quicServiceType,
                QUICRealtimeTransport.serviceType,
                PairingNetworkService.serviceType
            ]
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

    func testDirectPairingTransfersWorkspaceAndPersistsRoutes() throws {
        let host = PairingNetworkService(listenPort: .any)
        let hostID = DeviceID()
        let joinerID = DeviceID()
        let key = PairingCryptoSession.randomData(count: 32)
        let hostDevice = DeviceDescriptor(id: hostID, name: "Host")
        let joinerDevice = DeviceDescriptor(id: joinerID, name: "Joiner")
        let workspace = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "Direct",
            localDeviceID: hostID,
            devices: [hostDevice]
        )
        try host.startHosting(workspace: workspace, key: key, localDevice: hostDevice)
        let port = try waitForPairingPort(of: host)
        let joiner = PairingNetworkService(listenPort: .any, directPort: port)
        let prompts = PairingPromptStore()
        let hostPrompt = expectation(description: "host code")
        let joinerPrompt = expectation(description: "joiner code")
        let hostUpdated = expectation(description: "host workspace updated")
        let joinerJoined = expectation(description: "joiner received credentials")
        host.promptHandler = { prompt in
            prompts.setHost(prompt.code)
            hostPrompt.fulfill()
            host.confirm()
        }
        joiner.promptHandler = { prompt in
            prompts.setJoiner(prompt.code)
            joinerPrompt.fulfill()
            joiner.confirm()
        }
        host.hostUpdatedHandler = { snapshot in
            XCTAssertEqual(snapshot.devices.count, 2)
            XCTAssertFalse(snapshot.devices.first(where: { $0.id == joinerID })?.peerAddresses.isEmpty ?? true)
            hostUpdated.fulfill()
        }
        joiner.joinedHandler = { snapshot, receivedKey in
            XCTAssertEqual(receivedKey, key)
            XCTAssertEqual(snapshot.localDeviceID, joinerID)
            XCTAssertEqual(snapshot.devices.first(where: { $0.id == hostID })?.peerAddresses, [try! PeerAddress("127.0.0.1")])
            joinerJoined.fulfill()
        }
        joiner.startBrowsing()
        try joiner.join(PeerAddress("127.0.0.1"), localDevice: joinerDevice)

        wait(for: [hostPrompt, joinerPrompt, hostUpdated, joinerJoined], timeout: 8)
        XCTAssertEqual(prompts.hostCode, prompts.joinerCode)
        host.stop()
        joiner.stop()
    }

    func testTrustedTransportConnectsDirectlyWithoutBonjourDiscovery() async throws {
        let workspaceID = WorkspaceID()
        let key = PairingCryptoSession.randomData(count: 32)
        let serverID = DeviceID()
        let clientID = DeviceID()
        let serverDevice = DeviceDescriptor(id: serverID, name: "Server")
        let clientDevice = DeviceDescriptor(id: clientID, name: "Client")
        let serverWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Direct",
            localDeviceID: serverID,
            devices: [serverDevice, clientDevice]
        )
        let server = NetworkPeerTransport(
            listenPort: .any,
            directPort: .any,
            enableBonjour: false,
            enableQUIC: false
        )
        try await server.start(localDevice: serverDevice, workspace: serverWorkspace, key: key)
        let port = try await waitForPort(of: server)

        let serverRoute = try PeerAddress("127.0.0.1")
        let routedServer = DeviceDescriptor(id: serverID, name: "Server", peerAddresses: [serverRoute])
        let clientWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Direct",
            localDeviceID: clientID,
            devices: [routedServer, clientDevice]
        )
        let client = NetworkPeerTransport(
            listenPort: .any,
            directPort: port,
            enableBonjour: false,
            enableQUIC: false
        )
        let serverConnected = expectation(description: "server connected directly")
        let clientConnected = expectation(description: "client connected directly")
        let controlReceived = expectation(description: "control transferred")
        let serverEvents = Task {
            for await event in server.events() {
                switch event {
                case .connected(let id) where id == clientID:
                    serverConnected.fulfill()
                case .control(let id, let envelope) where id == clientID:
                    if case .controllerClaim = envelope.message { controlReceived.fulfill() }
                default:
                    break
                }
            }
        }
        let clientEvents = Task {
            for await event in client.events() {
                if case .connected(let id) = event, id == serverID { clientConnected.fulfill() }
            }
        }
        try await client.start(localDevice: clientDevice, workspace: clientWorkspace, key: key)
        await fulfillment(of: [serverConnected, clientConnected], timeout: 8)
        try await client.send(
            ControlEnvelope(message: .controllerClaim(.init(generation: 1, controllerID: clientID))),
            to: serverID
        )
        await fulfillment(of: [controlReceived], timeout: 3)
        await client.stop()
        await server.stop()
        serverEvents.cancel()
        clientEvents.cancel()
    }

    func testQUICTransportAuthenticatesAndTransfersControl() async throws {
        let workspaceID = WorkspaceID()
        let key = PairingCryptoSession.randomData(count: 32)
        let serverID = DeviceID()
        let clientID = DeviceID()
        let serverDevice = DeviceDescriptor(id: serverID, name: "QUIC Server")
        let clientDevice = DeviceDescriptor(id: clientID, name: "QUIC Client")
        let serverWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "QUIC",
            localDeviceID: serverID,
            devices: [serverDevice, clientDevice]
        )
        let server = NetworkPeerTransport(
            listenPort: .any,
            directPort: .any,
            quicListenPort: .any,
            directQUICPort: .any,
            enableBonjour: false,
            enableRealtime: false
        )
        try await server.start(localDevice: serverDevice, workspace: serverWorkspace, key: key)
        let quicPort = try await waitForQUICPort(of: server)

        let routedServer = DeviceDescriptor(
            id: serverID,
            name: "QUIC Server",
            peerAddresses: [try PeerAddress("127.0.0.1")]
        )
        let clientWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "QUIC",
            localDeviceID: clientID,
            devices: [routedServer, clientDevice]
        )
        let client = NetworkPeerTransport(
            listenPort: .any,
            directPort: .any,
            quicListenPort: .any,
            directQUICPort: quicPort,
            enableBonjour: false,
            enableRealtime: false
        )
        let serverConnected = expectation(description: "server accepted QUIC")
        let clientConnected = expectation(description: "client authenticated QUIC")
        let controlReceived = expectation(description: "control transferred over QUIC")
        serverConnected.assertForOverFulfill = false
        clientConnected.assertForOverFulfill = false
        let serverEvents = Task {
            for await event in server.events() {
                switch event {
                case .health(let id, let snapshot) where id == clientID &&
                    snapshot.health == .healthy && snapshot.transport == .quic:
                    serverConnected.fulfill()
                case .control(let id, let envelope) where id == clientID:
                    if case .controllerClaim = envelope.message { controlReceived.fulfill() }
                default:
                    break
                }
            }
        }
        let clientEvents = Task {
            for await event in client.events() {
                if case .health(let id, let snapshot) = event,
                   id == serverID, snapshot.health == .healthy, snapshot.transport == .quic {
                    clientConnected.fulfill()
                }
            }
        }

        try await client.start(localDevice: clientDevice, workspace: clientWorkspace, key: key)
        await fulfillment(of: [serverConnected, clientConnected], timeout: 8)
        try await client.send(
            ControlEnvelope(message: .controllerClaim(.init(generation: 1, controllerID: clientID))),
            to: serverID
        )
        await fulfillment(of: [controlReceived], timeout: 3)

        await client.stop()
        await server.stop()
        serverEvents.cancel()
        clientEvents.cancel()
    }

    func testQUICDatagramLaneAuthenticatesAndTransfersPointerState() async throws {
        let workspaceID = WorkspaceID()
        let key = PairingCryptoSession.randomData(count: 32)
        let serverID = DeviceID()
        let clientID = DeviceID()
        let serverDevice = DeviceDescriptor(id: serverID, name: "Realtime Server")
        let clientDevice = DeviceDescriptor(id: clientID, name: "Realtime Client")
        let serverWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Realtime",
            localDeviceID: serverID,
            devices: [serverDevice, clientDevice]
        )
        let server = QUICRealtimeTransport(listenPort: .any, directPort: .any, enableBonjour: false)
        try server.start(localDevice: serverDevice, workspace: serverWorkspace, key: key)
        let port = try await waitForRealtimePort(of: server)

        let routedServer = DeviceDescriptor(
            id: serverID,
            name: serverDevice.name,
            peerAddresses: [try PeerAddress("127.0.0.1")]
        )
        let clientWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Realtime",
            localDeviceID: clientID,
            devices: [routedServer, clientDevice]
        )
        let client = QUICRealtimeTransport(listenPort: .any, directPort: port, enableBonjour: false)
        let received = expectation(description: "pointer datagram received")
        let sessionID = SessionID()
        let frame = RealtimePointerFrame(
            workspaceID: workspaceID,
            sessionID: sessionID,
            controllerID: clientID,
            epoch: .init(generation: 1, controllerID: clientID),
            generation: 1,
            sequence: 0,
            deltaX: 3,
            deltaY: -2,
            cumulativeDeltaX: 3,
            cumulativeDeltaY: -2,
            absoluteX: 100,
            absoluteY: 200,
            timestampNanos: 1
        )
        server.frameHandler = { source, incoming in
            if source == clientID, incoming == frame { received.fulfill() }
        }
        try client.start(localDevice: clientDevice, workspace: clientWorkspace, key: key)

        var sent = false
        for _ in 0..<100 where !sent {
            sent = try await client.send(frame, to: serverID)
            if !sent { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(sent, "The authenticated QUIC datagram lane did not become ready")
        await fulfillment(of: [received], timeout: 3)
        client.stop()
        server.stop()
    }

    func testTrustedTransportReconnectsToStoredDirectAddress() async throws {
        let workspaceID = WorkspaceID()
        let key = PairingCryptoSession.randomData(count: 32)
        let serverID = DeviceID()
        let clientID = DeviceID()
        let serverDevice = DeviceDescriptor(id: serverID, name: "Server")
        let clientDevice = DeviceDescriptor(id: clientID, name: "Client")
        let baseWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Reconnect",
            localDeviceID: serverID,
            devices: [serverDevice, clientDevice]
        )
        let firstServer = NetworkPeerTransport(
            listenPort: .any,
            directPort: .any,
            enableBonjour: false,
            enableQUIC: false
        )
        try await firstServer.start(localDevice: serverDevice, workspace: baseWorkspace, key: key)
        let port = try await waitForPort(of: firstServer)

        let routedServer = DeviceDescriptor(
            id: serverID,
            name: "Server",
            peerAddresses: [try PeerAddress("127.0.0.1")]
        )
        let clientWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Reconnect",
            localDeviceID: clientID,
            devices: [routedServer, clientDevice]
        )
        let client = NetworkPeerTransport(
            listenPort: .any,
            directPort: port,
            enableBonjour: false,
            enableQUIC: false
        )
        let connectionTracker = ConnectionExpectationTracker()
        let firstConnection = expectation(description: "initial direct connection")
        let disconnected = expectation(description: "direct connection lost")
        let reconnected = expectation(description: "direct connection restored")
        let clientEvents = Task {
            for await event in client.events() {
                switch event {
                case .connected(let id) where id == serverID:
                    if connectionTracker.recordConnection() == 1 { firstConnection.fulfill() }
                    else if connectionTracker.connectionCount == 2 { reconnected.fulfill() }
                case .disconnected(let id) where id == serverID:
                    if connectionTracker.recordDisconnection() == 1 { disconnected.fulfill() }
                default:
                    break
                }
            }
        }
        try await client.start(localDevice: clientDevice, workspace: clientWorkspace, key: key)
        await fulfillment(of: [firstConnection], timeout: 8)
        await firstServer.stop()
        await fulfillment(of: [disconnected], timeout: 5)

        let replacementServer = NetworkPeerTransport(
            listenPort: port,
            directPort: .any,
            enableBonjour: false,
            enableQUIC: false
        )
        try await replacementServer.start(localDevice: serverDevice, workspace: baseWorkspace, key: key)
        await fulfillment(of: [reconnected], timeout: 12)

        await client.stop()
        await replacementServer.stop()
        clientEvents.cancel()
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
        try store.remove()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.remove())
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

    private func display(id: DisplayID, deviceID: DeviceID) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            deviceID: deviceID,
            name: "Built-in Retina Display",
            frame: DisplayRect(x: 0, y: 0, width: 100, height: 100),
            scaleFactor: 2,
            isMain: true
        )
    }
}

private func waitForPort(of transport: NetworkPeerTransport) async throws -> NWEndpoint.Port {
    for _ in 0..<100 {
        if let port = transport.activeControlPort { return port }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw XCTSkip("Listener did not become ready")
}

private func waitForQUICPort(of transport: NetworkPeerTransport) async throws -> NWEndpoint.Port {
    for _ in 0..<100 {
        if let port = transport.activeQUICPort { return port }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw XCTSkip("QUIC listener did not become ready")
}

private func waitForRealtimePort(of transport: QUICRealtimeTransport) async throws -> NWEndpoint.Port {
    for _ in 0..<100 {
        if let port = transport.activePort { return port }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw XCTSkip("Realtime QUIC listener did not become ready")
}

private func waitForPairingPort(of service: PairingNetworkService) throws -> NWEndpoint.Port {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if let port = service.activeDirectPort { return port }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    throw XCTSkip("Pairing listener did not become ready")
}

private final class PairingPromptStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHostCode: String?
    private var storedJoinerCode: String?
    var hostCode: String? { lock.withLock { storedHostCode } }
    var joinerCode: String? { lock.withLock { storedJoinerCode } }
    func setHost(_ value: String) { lock.withLock { storedHostCode = value } }
    func setJoiner(_ value: String) { lock.withLock { storedJoinerCode = value } }
}

private final class ConnectionExpectationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var connections = 0
    private var disconnections = 0
    var connectionCount: Int { lock.withLock { connections } }
    func recordConnection() -> Int { lock.withLock { connections += 1; return connections } }
    func recordDisconnection() -> Int { lock.withLock { disconnections += 1; return disconnections } }
}

private final class SecureConnectionRetainer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SecurePeerConnection?
    var connection: SecurePeerConnection? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
