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
}
