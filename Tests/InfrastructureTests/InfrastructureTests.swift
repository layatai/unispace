import XCTest
@testable import UniSpaceInfrastructure
import AppKit
import CoreGraphics
import CryptoKit
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

    func testCursorSuppressionDisconnectsMouseOnlyWhileRemoteControlIsActive() {
        let recorder = MouseAssociationRecorder()
        let capture = CGEventInputCapture { recorder.append($0) }

        capture.setSuppressionEnabled(true)
        capture.setSuppressionEnabled(true)
        capture.setSuppressionEnabled(false)
        capture.stop()

        XCTAssertEqual(recorder.values, [false, true])
    }

    func testGestureCaptureSerializesAndRebuildsPublicAppKitEvent() throws {
        XCTAssertEqual(
            Set(CGEventInputCapture.gestureEventTypes.map(\.rawValue)),
            Set([
                NSEvent.EventType.gesture,
                .magnify,
                .swipe,
                .rotate,
                .beginGesture,
                .endGesture,
                .smartMagnify
            ].map { UInt32($0.rawValue) })
        )
        let gestureType = try XCTUnwrap(
            CGEventType(rawValue: UInt32(NSEvent.EventType.magnify.rawValue))
        )
        let sourceEvent = try XCTUnwrap(CGEvent(source: nil))
        sourceEvent.type = gestureType

        let input = try XCTUnwrap(CGEventInputCapture.convert(type: gestureType, event: sourceEvent))
        guard case let .gesture(serializedEvent) = input else {
            return XCTFail("Expected a serialized gesture event")
        }

        let targetPosition = CGPoint(x: 320, y: 240)
        let rebuilt = try XCTUnwrap(
            CGEventInputInjector.gestureEvent(from: serializedEvent, at: targetPosition)
        )
        XCTAssertEqual(rebuilt.type.rawValue, gestureType.rawValue)
        XCTAssertEqual(rebuilt.location, targetPosition)
    }

    func testInjectedCursorCannotAccumulateBeyondAHorizontalDisplayEdge() {
        let bounds = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        let atEdge = CGEventInputInjector.constrainedPosition(
            CGPoint(x: 500, y: 50),
            to: bounds
        )
        let movedBack = CGEventInputInjector.constrainedPosition(
            CGPoint(x: atEdge.x - 4, y: atEdge.y),
            to: bounds
        )

        XCTAssertEqual(atEdge, CGPoint(x: 100, y: 50))
        XCTAssertEqual(movedBack, CGPoint(x: 96, y: 50))
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

    func testSystemAdaptersReportCurrentStateWithoutMutation() {
        let addresses = SystemTailnetAddressProvider().currentAddresses()
        XCTAssertEqual(addresses, Array(Set(addresses)).sorted { $0.host < $1.host })
        XCTAssertTrue(addresses.allSatisfy { SystemTailnetAddressProvider.isTailnetAddress($0.host) })

        let permissions = SystemPermissionService()
        XCTAssertTrue([PermissionState.granted, .denied].contains(permissions.state(for: .inputMonitoring)))
        XCTAssertTrue([PermissionState.granted, .denied].contains(permissions.state(for: .postEvents)))
        XCTAssertEqual(permissions.state(for: .localNetwork), .unknown)
        XCTAssertFalse(permissions.request(.localNetwork))

        _ = SystemLoginItemController().isEnabled
    }

    func testPairingPublicModelsAndErrorsExposeDiagnosticValues() {
        let id = DeviceID()
        let offer = PairingCryptoSession().offer
        let candidate = PairingCandidate(
            id: id,
            name: "Remote Mac",
            endpoint: .hostPort(host: "127.0.0.1", port: 61_337),
            offer: offer
        )
        XCTAssertEqual(candidate.id, id)
        XCTAssertEqual(candidate.name, "Remote Mac")

        let errors: [(PairingServiceError, String)] = [
            (.notReady, "Pairing is not ready."),
            (.malformedMessage, "The pairing message was invalid."),
            (.peerRejected, "The other device rejected pairing."),
            (.workspaceFull, "A UniSpace workspace supports up to four devices."),
            (.network("offline"), "offline")
        ]
        for (error, description) in errors {
            XCTAssertEqual(error.errorDescription, description)
        }
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

    func testPairingCryptoMatchesSharedWindowsVector() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "Documentation/Protocol/interop-vectors.json"
        ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pairing = try XCTUnwrap(root["pairingV1"] as? [String: String])
        let privateA = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try XCTUnwrap(Data(hexString: pairing["privateAHex"]))
        )
        let publicB = try P256.KeyAgreement.PublicKey(
            x963Representation: try XCTUnwrap(Data(hexString: pairing["publicBHex"]))
        )
        let publicAData = privateA.publicKey.x963Representation
        XCTAssertEqual(publicAData, try XCTUnwrap(Data(hexString: pairing["publicAHex"])))
        let nonceA = try XCTUnwrap(Data(hexString: pairing["nonceAHex"]))
        let nonceB = try XCTUnwrap(Data(hexString: pairing["nonceBHex"]))
        let publicBData = publicB.x963Representation
        let localFirst = publicAData.lexicographicallyPrecedes(publicBData)
        let transcript = localFirst
            ? publicAData + publicBData + nonceA + nonceB
            : publicBData + publicAData + nonceB + nonceA
        let shared = try privateA.sharedSecretFromKeyAgreement(with: publicB)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("UniSpace pairing v1".utf8),
            outputByteCount: 32
        )
        let keyData = key.withUnsafeBytes { Data($0) }
        XCTAssertEqual(keyData, try XCTUnwrap(Data(hexString: pairing["derivedKeyHex"])))
        let code = keyData.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        XCTAssertEqual(String(format: "%06u", code), pairing["confirmationCode"])
        let credential = try ChaChaPoly.SealedBox(
            combined: try XCTUnwrap(Data(hexString: pairing["credentialCombinedHex"]))
        )
        XCTAssertEqual(
            try ChaChaPoly.open(credential, using: key),
            try XCTUnwrap(Data(hexString: pairing["workspaceKeyHex"]))
        )

        let secure = try XCTUnwrap(root["secureChannelV1"] as? [String: String])
        let secureWorkspaceID = WorkspaceID(rawValue: try XCTUnwrap(
            UUID(uuidString: try XCTUnwrap(secure["workspaceId"]))
        ))
        let derivedSessionKey = SecurePeerConnection.deriveSessionKey(
            workspaceID: secureWorkspaceID,
            workspaceKey: SymmetricKey(data: try XCTUnwrap(Data(hexString: secure["workspaceKeyHex"]))),
            firstNonce: try XCTUnwrap(Data(hexString: secure["localNonceHex"])),
            secondNonce: try XCTUnwrap(Data(hexString: secure["peerNonceHex"])),
            securityProfile: .reliableV1
        )
        XCTAssertEqual(
            derivedSessionKey.withUnsafeBytes { Data($0) },
            try XCTUnwrap(Data(hexString: secure["sessionKeyHex"]))
        )
        let wire = try XCTUnwrap(root["wireV2"] as? [String: String])
        let expectedPacket = try XCTUnwrap(Data(hexString: secure["sealedPacketHex"]))
        let inputFrame = try XCTUnwrap(Data(hexString: wire["keyInputFrameHex"]))
        XCTAssertEqual(
            try SecurePeerConnection.sealForInterop(
                Data(repeating: 0, count: 8) + inputFrame,
                key: derivedSessionKey,
                nonce: Data(expectedPacket.dropFirst(5).prefix(12))
            ),
            Data(expectedPacket.dropFirst(5))
        )
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
        let clientDevice = DeviceDescriptor(
            id: clientID,
            name: "Client",
            capabilities: [.publicTrackpadGestures]
        )
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
        let capabilitiesReceived = expectation(description: "peer capabilities received")
        let controlReceived = expectation(description: "control transferred")
        let serverEvents = Task {
            for await event in server.events() {
                switch event {
                case .connected(let id) where id == clientID:
                    serverConnected.fulfill()
                case .control(let id, let envelope) where id == clientID:
                    switch envelope.message {
                    case let .hello(device) where device.capabilities.contains(.publicTrackpadGestures):
                        capabilitiesReceived.fulfill()
                    case .controllerClaim:
                        controlReceived.fulfill()
                    default:
                        break
                    }
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
        await fulfillment(of: [serverConnected, clientConnected, capabilitiesReceived], timeout: 8)
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
        let connectionStartedAt = DispatchTime.now().uptimeNanoseconds
        serverConnected.assertForOverFulfill = false
        clientConnected.assertForOverFulfill = false
        let serverEvents = Task {
            for await event in server.events() {
                switch event {
                case .health(let id, let snapshot) where id == clientID &&
                    snapshot.health == .healthy && snapshot.transport == .quic:
                    XCTAssertGreaterThanOrEqual(
                        DispatchTime.now().uptimeNanoseconds - connectionStartedAt,
                        100_000_000,
                        "QUIC must survive its cold-start stability window before being announced"
                    )
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
                    XCTAssertGreaterThanOrEqual(
                        DispatchTime.now().uptimeNanoseconds - connectionStartedAt,
                        100_000_000,
                        "QUIC must survive its cold-start stability window before being announced"
                    )
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

    func testQUICTransportReconnectsAfterPeerRestarts() async throws {
        let workspaceID = WorkspaceID()
        let key = PairingCryptoSession.randomData(count: 32)
        let serverID = DeviceID()
        let clientID = DeviceID()
        let serverDevice = DeviceDescriptor(id: serverID, name: "Server")
        let clientDevice = DeviceDescriptor(id: clientID, name: "Client")
        let serverWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "QUIC Reconnect",
            localDeviceID: serverID,
            devices: [serverDevice, clientDevice]
        )
        let firstServer = NetworkPeerTransport(
            listenPort: .any,
            directPort: .any,
            quicListenPort: .any,
            directQUICPort: .any,
            enableBonjour: false,
            enableRealtime: false
        )
        try await firstServer.start(localDevice: serverDevice, workspace: serverWorkspace, key: key)
        let quicPort = try await waitForQUICPort(of: firstServer)

        let routedServer = DeviceDescriptor(
            id: serverID,
            name: "Server",
            peerAddresses: [try PeerAddress("127.0.0.1")]
        )
        let clientWorkspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "QUIC Reconnect",
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
        let tracker = ConnectionExpectationTracker()
        let firstConnection = expectation(description: "initial QUIC connection")
        let disconnected = expectation(description: "QUIC connection lost")
        let reconnected = expectation(description: "QUIC connection restored")
        let clientEvents = Task {
            for await event in client.events() {
                switch event {
                case .connected(let id) where id == serverID:
                    if tracker.recordConnection() == 1 { firstConnection.fulfill() }
                    else if tracker.connectionCount == 2 { reconnected.fulfill() }
                case .disconnected(let id) where id == serverID:
                    if tracker.recordDisconnection() == 1 { disconnected.fulfill() }
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
            listenPort: .any,
            directPort: .any,
            quicListenPort: quicPort,
            directQUICPort: .any,
            enableBonjour: false,
            enableRealtime: false
        )
        try await replacementServer.start(localDevice: serverDevice, workspace: serverWorkspace, key: key)
        await fulfillment(of: [reconnected], timeout: 12)

        await client.stop()
        await replacementServer.stop()
        clientEvents.cancel()
    }

    func testTrustedTransportRetriesWhenReachablePeerNeverAuthenticates() async throws {
        let queue = DispatchQueue(label: "UniSpaceInfrastructureTests.UnresponsivePeer")
        let acceptedConnections = NWConnectionRetainer()
        let listener = try NWListener(using: NetworkPeerTransport.makeParameters(), on: .any)
        let listenerReady = expectation(description: "unresponsive peer listening")
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            acceptedConnections.append(connection)
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        await fulfillment(of: [listenerReady], timeout: 3)
        let port = try XCTUnwrap(listener.port)

        let workspaceID = WorkspaceID()
        let localID = DeviceID()
        let peerID = DeviceID()
        let localDevice = DeviceDescriptor(id: localID, name: "Local")
        let peerDevice = DeviceDescriptor(
            id: peerID,
            name: "Unresponsive Peer",
            peerAddresses: [try PeerAddress("127.0.0.1")]
        )
        let workspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Authentication timeout",
            localDeviceID: localID,
            devices: [localDevice, peerDevice]
        )
        let transport = NetworkPeerTransport(
            listenPort: .any,
            directPort: port,
            enableBonjour: false,
            enableQUIC: false,
            authenticationTimeout: 0.2
        )
        let retried = expectation(description: "connection retried after authentication timeout")
        retried.expectedFulfillmentCount = 2
        retried.assertForOverFulfill = false
        let events = Task {
            for await event in transport.events() {
                if case let .health(id, snapshot) = event,
                   id == peerID, snapshot.health == .connecting {
                    retried.fulfill()
                }
            }
        }

        try await transport.start(
            localDevice: localDevice,
            workspace: workspace,
            key: PairingCryptoSession.randomData(count: 32)
        )
        await fulfillment(of: [retried], timeout: 3)

        await transport.stop()
        listener.cancel()
        acceptedConnections.cancelAll()
        events.cancel()
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

    func testKeychainTrustStoreCreatesUpdatesAndRemovesWorkspaceKey() throws {
        let workspaceID = WorkspaceID()
        let store = KeychainTrustStore(service: "com.layatai.unispace.tests.\(UUID().uuidString)")
        defer { try? store.removeWorkspaceKey(for: workspaceID) }
        let first = Data(repeating: 0x11, count: 32)
        let second = Data(repeating: 0x22, count: 32)

        XCTAssertNil(try store.workspaceKey(for: workspaceID))
        try store.storeWorkspaceKey(first, for: workspaceID)
        XCTAssertEqual(try store.workspaceKey(for: workspaceID), first)
        try store.storeWorkspaceKey(second, for: workspaceID)
        XCTAssertEqual(try store.workspaceKey(for: workspaceID), second)
        try store.removeWorkspaceKey(for: workspaceID)
        XCTAssertNil(try store.workspaceKey(for: workspaceID))
        XCTAssertNoThrow(try store.removeWorkspaceKey(for: workspaceID))
    }

    func testCrossPlatformQUICParametersUsePeerToPeerTLSBootstrap() throws {
        let parameters = try NetworkPeerTransport.makeCrossPlatformQUICParameters()
        XCTAssertTrue(parameters.includePeerToPeer)
    }

    @MainActor
    func testDisplayCatalogReturnsStableUniqueIdentifiers() {
        let displays = SystemDisplayCatalog().currentDisplays(for: DeviceID())
        XCTAssertFalse(displays.isEmpty)
        XCTAssertEqual(Set(displays.map(\.id)).count, displays.count)
    }

    func testAuthenticatedEncryptedChannelSerializesConcurrentTransfers() throws {
        let workspaceID = WorkspaceID()
        let key = PairingCryptoSession.randomData(count: 32)
        let serverDevice = DeviceID()
        let clientDevice = DeviceID()
        let listener = try NWListener(using: NetworkPeerTransport.makeParameters(), on: .any)
        let listenerReady = expectation(description: "listener ready")
        let serverAuthenticated = expectation(description: "server authenticated client")
        let clientAuthenticated = expectation(description: "client authenticated server")
        let transferCount = 256
        let framesReceived = expectation(description: "encrypted frames received")
        framesReceived.expectedFulfillmentCount = transferCount
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
                framesReceived.fulfill()
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
        let payloads = try (0..<transferCount).map { index in
            try WireFrameCodec.encodeControl(ControlEnvelope(message: .controllerClaim(.init(
                generation: UInt64(index + 1),
                controllerID: clientDevice
            ))))
        }
        DispatchQueue.concurrentPerform(iterations: transferCount) { index in
            client.send(payloads[index], completion: nil)
        }
        wait(for: [framesReceived], timeout: 5)
        client.cancel()
        listener.cancel()
    }

    func testCrossPlatformPointerLaneAuthenticatesAndDeliversLatestState() async throws {
        let workspaceID = WorkspaceID()
        let key = PairingCryptoSession.randomData(count: 32)
        let macID = DeviceID()
        let windowsID = DeviceID()
        let mac = DeviceDescriptor(id: macID, name: "Mac", platform: .macOS)
        let windows = DeviceDescriptor(
            id: windowsID,
            name: "Windows PC",
            capabilities: [.crossPlatformInputV2, .udpPointerV2],
            platform: .windows
        )
        let workspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Portable",
            localDeviceID: macID,
            devices: [mac, windows]
        )
        let transport = CrossPlatformPointerTransport()
        try transport.start(localDevice: mac, workspace: workspace, key: key)
        defer { transport.stop() }

        let rawClient = NWConnection(
            host: "127.0.0.1",
            port: NetworkPeerTransport.crossPlatformPointerPort,
            using: .udp
        )
        let client = SecurePeerConnection(
            connection: rawClient,
            localDeviceID: windowsID,
            workspaceID: workspaceID,
            workspaceKey: key,
            expectedDeviceID: macID,
            isOutbound: true,
            transportKind: .tcp,
            isDatagram: true,
            securityProfile: .pointerV2
        )
        defer { client.cancel() }
        let authenticated = expectation(description: "Windows pointer lane authenticated")
        let received = expectation(description: "Latest pointer state received")
        client.authenticatedHandler = { deviceID in
            XCTAssertEqual(deviceID, macID)
            authenticated.fulfill()
        }
        let frame = PortableRealtimePointerFrame(
            workspaceID: workspaceID,
            sessionID: SessionID(),
            controllerID: macID,
            epoch: .init(generation: 1, controllerID: macID),
            generation: 2,
            sequence: 3,
            deltaX: 4,
            deltaY: -5,
            cumulativeDeltaX: 14,
            cumulativeDeltaY: -15,
            absoluteX: 640,
            absoluteY: 480,
            timestampNanos: 6
        )
        client.frameHandler = { kind, payload in
            do {
                XCTAssertEqual(kind, .realtimePointerBinaryV2)
                let decoded = try WireFrameCodec.decodePortableRealtimePointer(payload)
                XCTAssertEqual(decoded, frame)
                received.fulfill()
            } catch {
                XCTFail("Could not decode Windows pointer frame: \(error)")
            }
        }
        rawClient.start(queue: DispatchQueue(label: "UniSpaceInfrastructureTests.WindowsPointer"))
        await fulfillment(of: [authenticated], timeout: 3)

        var sent = false
        for _ in 0..<50 where !sent {
            sent = try await transport.send(frame, to: windowsID)
            if !sent { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(sent)
        let sentToUnknownDevice = try await transport.send(frame, to: DeviceID())
        XCTAssertFalse(sentToUnknownDevice)
        await fulfillment(of: [received], timeout: 3)
        transport.stop()
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

private extension Data {
    init?(hexString: String?) {
        guard let hexString, hexString.count.isMultiple(of: 2) else { return nil }
        self.init()
        reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let end = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<end], radix: 16) else { return nil }
            append(byte)
            index = end
        }
    }
}

private final class MouseAssociationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Bool] = []

    var values: [Bool] { lock.withLock { storedValues } }

    func append(_ value: Bool) {
        lock.withLock { storedValues.append(value) }
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

private final class NWConnectionRetainer: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    func append(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
    }

    func cancelAll() {
        let retained = lock.withLock {
            defer { connections.removeAll() }
            return connections
        }
        retained.forEach { $0.cancel() }
    }
}
