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
            connectedDeviceIDs: [incompatible.id]
        ))
    }

    private func device(_ uuid: String) -> DeviceDescriptor {
        DeviceDescriptor(
            id: DeviceID(rawValue: UUID(uuidString: uuid)!),
            name: uuid,
            capabilities: [.clipboardTextV1, .clipboardURLV1]
        )
    }
}
