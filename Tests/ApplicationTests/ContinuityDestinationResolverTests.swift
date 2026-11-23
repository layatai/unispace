import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class ContinuityDestinationResolverTests: XCTestCase {
    func testResolverSelectsRemoteControllerBeforeClipboardConnectionExists() {
        let local = device("00000000-0000-0000-0000-000000000001")
        let controller = device("00000000-0000-0000-0000-000000000002")
        let sessionPeer = device("00000000-0000-0000-0000-000000000003")

        XCTAssertEqual(
            ContinuityDestinationResolver.resolve(
                localDeviceID: local.id,
                controllerID: controller.id,
                controlSession: .init(phase: .receiving, peerID: sessionPeer.id),
                devices: [local, controller, sessionPeer],
                connectedDeviceIDs: [controller.id, sessionPeer.id]
            ),
            controller.id
        )
    }

    func testExplainReportsWhyEachDestinationWasChosen() {
        let local = device("00000000-0000-0000-0000-000000000001")
        let peer = device("00000000-0000-0000-0000-000000000002")
        let other = device("00000000-0000-0000-0000-000000000003")
        let idle = ControlSessionSnapshot(phase: .idle, peerID: nil)

        func explain(
            _ session: ControlSessionSnapshot,
            connected: Set<DeviceID>
        ) -> (DeviceID?, ContinuityDestinationResolver.Reason) {
            let value = ContinuityDestinationResolver.explain(
                localDeviceID: local.id,
                controllerID: local.id,
                controlSession: session,
                devices: [local, peer, other],
                connectedDeviceIDs: connected
            )
            return (value.destination, value.reason)
        }

        XCTAssertTrue(explain(idle, connected: []) == (nil, .noCompatiblePeer))
        XCTAssertTrue(explain(idle, connected: [peer.id]) == (peer.id, .onlyConnectedPeer))
        XCTAssertTrue(explain(idle, connected: [peer.id, other.id]) == (nil, .ambiguous))
        XCTAssertTrue(explain(
            .init(phase: .controlling, peerID: other.id),
            connected: [peer.id, other.id]
        ) == (other.id, .activeControlSession))
    }

    func testResolverUsesActiveSessionThenSoleCompatiblePeer() {
        let local = device("00000000-0000-0000-0000-000000000001")
        let activePeer = device("00000000-0000-0000-0000-000000000002")
        let otherPeer = device("00000000-0000-0000-0000-000000000003")

        XCTAssertEqual(
            ContinuityDestinationResolver.resolve(
                localDeviceID: local.id,
                controllerID: local.id,
                controlSession: .init(phase: .controlling, peerID: activePeer.id),
                devices: [local, activePeer, otherPeer],
                connectedDeviceIDs: [activePeer.id, otherPeer.id]
            ),
            activePeer.id
        )
        XCTAssertEqual(
            ContinuityDestinationResolver.resolve(
                localDeviceID: local.id,
                controllerID: local.id,
                controlSession: .idle,
                devices: [local, activePeer, otherPeer],
                connectedDeviceIDs: [otherPeer.id]
            ),
            otherPeer.id
        )
    }

    func testResolverDoesNotDialAllPeersOrSelectIncompatibleDevices() {
        let local = device("00000000-0000-0000-0000-000000000001")
        let first = device("00000000-0000-0000-0000-000000000002")
        let second = device("00000000-0000-0000-0000-000000000003")
        let incompatible = DeviceDescriptor(
            id: DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!),
            name: "Old peer"
        )

        XCTAssertNil(ContinuityDestinationResolver.resolve(
            localDeviceID: local.id,
            controllerID: local.id,
            controlSession: .idle,
            devices: [local, first, second],
            connectedDeviceIDs: [first.id, second.id]
        ))
        XCTAssertNil(ContinuityDestinationResolver.resolve(
            localDeviceID: local.id,
            controllerID: incompatible.id,
            controlSession: .idle,
            devices: [local, incompatible],
            connectedDeviceIDs: [incompatible.id],
            requiredCapabilities: [.clipboardTextV1, .clipboardURLV1]
        ))
    }

    func testResolverSelectsOnlyPeersWithTheRequestedSecondaryCapability() {
        let local = device("00000000-0000-0000-0000-000000000001")
        let clipboardOnly = device("00000000-0000-0000-0000-000000000002")
        let filePeer = DeviceDescriptor(
            id: DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!),
            name: "File peer",
            capabilities: [.fileTransferV1]
        )

        XCTAssertEqual(ContinuityDestinationResolver.resolve(
            localDeviceID: local.id,
            controllerID: local.id,
            controlSession: .idle,
            devices: [local, clipboardOnly, filePeer],
            connectedDeviceIDs: [clipboardOnly.id, filePeer.id],
            requiredCapabilities: [.fileTransferV1]
        ), filePeer.id)
    }

    /// Regression: the live workspace pairs two Macs with Linux and Windows
    /// peers. While idle, offline peers must not hide the only connected Mac,
    /// and peers without clipboard capabilities never count as candidates.
    func testIdleMacKeepsClipboardRouteWhenOtherPairedPeersAreOfflineOrIncompatible() {
        let local = device("00000000-0000-0000-0000-00000000000A")
        let mac = device("00000000-0000-0000-0000-00000000000B")
        let linux = device("00000000-0000-0000-0000-00000000000C")
        let windows = DeviceDescriptor(
            id: DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!),
            name: "Windows",
            capabilities: [.crossPlatformInputV2],
            platform: .windows
        )
        let devices = [local, mac, linux, windows]
        func resolve(connected: Set<DeviceID>, session: ControlSessionSnapshot = .idle) -> DeviceID? {
            ContinuityDestinationResolver.resolve(
                localDeviceID: local.id,
                controllerID: nil,
                controlSession: session,
                devices: devices,
                connectedDeviceIDs: connected,
                requiredCapabilities: [.clipboardTextV1, .clipboardURLV1]
            )
        }

        XCTAssertEqual(resolve(connected: [mac.id]), mac.id, "Offline peers must not block the only connected Mac")
        XCTAssertEqual(resolve(connected: [mac.id, windows.id]), mac.id, "Incompatible peers never compete")
        XCTAssertNil(resolve(connected: [mac.id, linux.id]), "Two idle candidates are ambiguous")
        XCTAssertEqual(
            resolve(connected: [mac.id, linux.id], session: .init(phase: .controlling, peerID: mac.id)),
            mac.id,
            "An active session disambiguates between connected candidates"
        )
    }

    private func device(_ uuid: String) -> DeviceDescriptor {
        DeviceDescriptor(
            id: DeviceID(rawValue: UUID(uuidString: uuid)!),
            name: uuid,
            capabilities: [.clipboardTextV1, .clipboardURLV1]
        )
    }
}
