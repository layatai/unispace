import XCTest
@testable import UniSpaceDomain

final class DomainModelsTests: XCTestCase {
    func testPeerAddressNormalizesSupportedHostFormats() throws {
        XCTAssertEqual(try PeerAddress(" MacBook-Pro.tailnet.ts.net ").host, "macbook-pro.tailnet.ts.net")
        XCTAssertEqual(try PeerAddress("100.93.172.58").host, "100.93.172.58")
        XCTAssertEqual(try PeerAddress("[fd7a:115c:a1e0::1]").host, "fd7a:115c:a1e0::1")
    }

    func testPeerAddressRejectsURLsPathsAndPorts() {
        for invalid in ["", "https://mac.tailnet.ts.net", "mac.tailnet.ts.net/path", "mac:61337", "-mac"] {
            XCTAssertThrowsError(try PeerAddress(invalid), "Expected \(invalid) to be rejected")
        }
    }

    func testLegacyDeviceDescriptorDecodesWithoutPeerAddresses() throws {
        let id = DeviceID()
        let data = Data("{\"id\":{\"rawValue\":\"\(id.rawValue.uuidString)\"},\"name\":\"Legacy Mac\",\"displays\":[]}".utf8)

        let device = try JSONDecoder().decode(DeviceDescriptor.self, from: data)

        XCTAssertEqual(device.id, id)
        XCTAssertEqual(device.peerAddresses, [])
        XCTAssertEqual(device.capabilities, [])
    }

    func testDeviceCapabilitiesRoundTripAndPreserveUnknownValues() throws {
        let futureCapability = DeviceCapability(rawValue: "future-input-v2")
        let device = DeviceDescriptor(
            id: DeviceID(),
            name: "Modern Mac",
            capabilities: [.publicTrackpadGestures, futureCapability]
        )

        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(DeviceDescriptor.self, from: data)

        XCTAssertEqual(decoded, device)
    }

    func testLegacyDecoderIgnoresNewDeviceCapabilities() throws {
        let device = DeviceDescriptor(
            id: DeviceID(),
            name: "Modern Mac",
            capabilities: [.publicTrackpadGestures]
        )

        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(LegacyDeviceDescriptor.self, from: data)

        XCTAssertEqual(decoded.id, device.id)
        XCTAssertEqual(decoded.name, device.name)
    }

    func testControllerElectionUsesGenerationThenDeviceID() {
        let low = DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let high = DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        var election = ControllerStateMachine()

        XCTAssertTrue(election.observe(.init(generation: 4, controllerID: low)))
        XCTAssertTrue(election.observe(.init(generation: 4, controllerID: high)))
        XCTAssertFalse(election.observe(.init(generation: 3, controllerID: high)))
        XCTAssertEqual(election.currentEpoch, .init(generation: 4, controllerID: high))
        XCTAssertEqual(election.claim(for: low).generation, 5)
    }

    func testTopologyCreatesBidirectionalExclusiveLinks() {
        let first = DisplayEndpoint(displayID: DisplayID(), edge: .right)
        let second = DisplayEndpoint(displayID: DisplayID(), edge: .left)
        let replacement = DisplayEndpoint(displayID: DisplayID(), edge: .left)
        var topology = DisplayTopology()

        topology.connect(first, to: second)
        XCTAssertEqual(topology.destination(from: first.displayID, edge: first.edge), second)
        XCTAssertEqual(topology.destination(from: second.displayID, edge: second.edge), first)

        topology.connect(first, to: replacement)
        XCTAssertNil(topology.destination(from: second.displayID, edge: second.edge))
        XCTAssertEqual(topology.destination(from: first.displayID, edge: first.edge), replacement)
        XCTAssertEqual(topology.links.count, 2)
    }

    func testUpdatingDeviceDropsTopologyUsingRetiredCrossMacDisplayID() {
        let localID = DeviceID()
        let remoteID = DeviceID()
        let duplicateID = DisplayID()
        let newLocalDisplayID = DisplayID()
        let remoteExternalDisplayID = DisplayID()
        var topology = DisplayTopology()
        topology.connect(
            DisplayEndpoint(displayID: duplicateID, edge: .left),
            to: DisplayEndpoint(displayID: remoteExternalDisplayID, edge: .right)
        )
        var workspace = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "Test",
            localDeviceID: localID,
            devices: [
                DeviceDescriptor(
                    id: localID,
                    name: "Local",
                    displays: [display(id: duplicateID, deviceID: localID)]
                ),
                DeviceDescriptor(
                    id: remoteID,
                    name: "Remote",
                    displays: [
                        display(id: duplicateID, deviceID: remoteID),
                        display(id: remoteExternalDisplayID, deviceID: remoteID, name: "External", isMain: false)
                    ]
                )
            ],
            topology: topology
        )

        workspace.updateDevice(DeviceDescriptor(
            id: localID,
            name: "Local",
            displays: [display(id: newLocalDisplayID, deviceID: localID)]
        ))

        XCTAssertTrue(workspace.topology.links.isEmpty)
        XCTAssertEqual(Set(workspace.devices.flatMap { $0.displays.map(\.id) }).count, 3)
    }

    func testRemoteInputStateReleasesEveryPressedInput() {
        var state = RemoteInputState()
        state.apply(.key(code: 12, isDown: true, isRepeat: false))
        state.apply(.mouseButton(button: .left, isDown: true, clickCount: 1))

        let releases = state.releaseEvents()

        XCTAssertEqual(releases.count, 2)
        XCTAssertTrue(releases.contains(.key(code: 12, isDown: false, isRepeat: false)))
        XCTAssertTrue(releases.contains(.mouseButton(button: .left, isDown: false, clickCount: 1)))
        XCTAssertTrue(state.releaseEvents().isEmpty)
    }

    func testActivationClampsNormalizedPosition() {
        let epoch = ControllerEpoch(generation: 1, controllerID: DeviceID())
        XCTAssertEqual(
            InputActivation(sessionID: SessionID(), epoch: epoch, targetDisplayID: DisplayID(), entryEdge: .left, normalizedPosition: 2).normalizedPosition,
            1
        )
    }

    func testIdentifierAndPeerAddressDescriptionsExposeCanonicalValues() throws {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let address = try PeerAddress(" MacBook.tailnet.ts.net ")

        XCTAssertEqual(DeviceID(rawValue: uuid).description, uuid.uuidString)
        XCTAssertEqual(address.description, "macbook.tailnet.ts.net")
        XCTAssertEqual(try JSONDecoder().decode(PeerAddress.self, from: JSONEncoder().encode(address)), address)
        XCTAssertEqual(PeerAddressError.empty.errorDescription, "Enter a Tailscale hostname or IP address.")
        XCTAssertEqual(
            PeerAddressError.invalidFormat.errorDescription,
            "Enter a hostname or IP address without a URL, path, or port."
        )
    }

    func testEveryDisplayEdgeHasSymmetricOpposite() {
        let pairs: [(DisplayEdge, DisplayEdge)] = [
            (.left, .right),
            (.right, .left),
            (.top, .bottom),
            (.bottom, .top)
        ]

        for (edge, opposite) in pairs {
            XCTAssertEqual(edge.opposite, opposite)
            XCTAssertEqual(opposite.opposite, edge)
        }
    }

    func testEdgeLinkIdentityIncludesBothDirectedEndpoints() {
        let first = DisplayEndpoint(displayID: DisplayID(), edge: .left)
        let second = DisplayEndpoint(displayID: DisplayID(), edge: .right)
        let link = EdgeLink(source: first, destination: second)

        XCTAssertEqual(
            link.id,
            "\(first.displayID)-left-\(second.displayID)-right"
        )
    }

    func testWorkspaceUpdateReplacesKnownDeviceAndAppendsNewDevice() {
        let localID = DeviceID()
        let remoteID = DeviceID()
        let localDisplay = display(id: DisplayID(), deviceID: localID)
        var workspace = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "Test",
            localDeviceID: localID,
            devices: [DeviceDescriptor(id: localID, name: "Before", displays: [localDisplay])]
        )

        workspace.updateDevice(DeviceDescriptor(id: localID, name: "After", displays: [localDisplay]))
        workspace.updateDevice(DeviceDescriptor(id: remoteID, name: "Remote"))

        XCTAssertEqual(workspace.devices.count, 2)
        XCTAssertEqual(workspace.devices.first { $0.id == localID }?.name, "After")
        XCTAssertEqual(workspace.devices.first { $0.id == remoteID }?.name, "Remote")
    }

    private func display(
        id: DisplayID,
        deviceID: DeviceID,
        name: String = "Built-in Retina Display",
        isMain: Bool = true
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            deviceID: deviceID,
            name: name,
            frame: DisplayRect(x: 0, y: 0, width: 100, height: 100),
            scaleFactor: 2,
            isMain: isMain
        )
    }
}

private struct LegacyDeviceDescriptor: Decodable {
    let id: DeviceID
    let name: String
}
