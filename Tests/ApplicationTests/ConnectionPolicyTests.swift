import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class ConnectionPolicyTests: XCTestCase {
    func testControllerOwnsMacDialingAndNeverDialsWindows() {
        let controller = device("00000000-0000-0000-0000-000000000002", platform: .macOS)
        let receiver = device("00000000-0000-0000-0000-000000000003", platform: .macOS)
        let windows = device("00000000-0000-0000-0000-000000000004", platform: .windows)
        let workspace = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "Policy",
            localDeviceID: controller.id,
            devices: [controller, receiver, windows]
        )

        let controllerPolicy = ControlConnectionRoutingPolicy.policy(
            localDeviceID: controller.id,
            workspace: workspace,
            controllerID: controller.id
        )
        XCTAssertEqual(controllerPolicy.outboundPeerIDs, [receiver.id])
        XCTAssertTrue(controllerPolicy.ownsReconnect(to: receiver.id))
        XCTAssertFalse(controllerPolicy.ownsReconnect(to: windows.id))
        XCTAssertEqual(
            ControlConnectionRoutingPolicy.policy(
                localDeviceID: receiver.id,
                workspace: workspace,
                controllerID: controller.id
            ),
            .passive
        )
    }

    func testLowestMacBootstrapsWorkspaceWithoutPersistedController() {
        let lowest = device("00000000-0000-0000-0000-000000000001", platform: .unknown)
        let other = device("00000000-0000-0000-0000-000000000002", platform: .macOS)
        let windows = device("00000000-0000-0000-0000-000000000000", platform: .windows)
        let workspace = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "Bootstrap",
            localDeviceID: lowest.id,
            devices: [windows, other, lowest]
        )

        XCTAssertEqual(
            ControlConnectionRoutingPolicy.policy(
                localDeviceID: lowest.id,
                workspace: workspace,
                controllerID: nil
            ).outboundPeerIDs,
            [other.id]
        )
        XCTAssertEqual(
            ControlConnectionRoutingPolicy.policy(
                localDeviceID: other.id,
                workspace: workspace,
                controllerID: nil
            ),
            .passive
        )
    }

    func testControlSessionSnapshotProtectsOnlyLiveSessionPhases() {
        XCTAssertFalse(ControlSessionSnapshot.idle.protectsInputLatency)
        for phase in [ControlSessionPhase.activating, .controlling, .receiving] {
            XCTAssertTrue(ControlSessionSnapshot(phase: phase).protectsInputLatency)
        }
    }

    func testMacOutboundPolicyRejectsWindowsAndMissingPeers() {
        XCTAssertFalse(PeerConnectionPolicy.macCanDial(nil))
        XCTAssertFalse(PeerConnectionPolicy.macCanDial(device(
            "00000000-0000-0000-0000-000000000001",
            platform: .windows
        )))
        XCTAssertTrue(PeerConnectionPolicy.macCanDial(device(
            "00000000-0000-0000-0000-000000000002",
            platform: .unknown
        )))
    }

    private func device(_ uuid: String, platform: DevicePlatform) -> DeviceDescriptor {
        DeviceDescriptor(
            id: DeviceID(rawValue: UUID(uuidString: uuid)!),
            name: uuid,
            platform: platform
        )
    }
}
