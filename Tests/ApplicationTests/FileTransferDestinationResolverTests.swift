import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class FileTransferDestinationResolverTests: XCTestCase {
    func testResolverUsesExplicitSelectionThenControlTargetThenStableConnectedFallback() {
        let selected = DeviceDescriptor(id: DeviceID(), name: "Zebra")
        let controlTarget = DeviceDescriptor(id: DeviceID(), name: "Middle")
        let fallback = DeviceDescriptor(id: DeviceID(), name: "Alpha")
        let connected = Set([selected.id, controlTarget.id, fallback.id])
        let candidates = [selected, controlTarget, fallback]

        XCTAssertEqual(
            FileTransferDestinationResolver.resolve(
                selectedDeviceID: selected.id,
                continuityTargetID: controlTarget.id,
                candidates: candidates,
                connectedDeviceIDs: connected
            ),
            selected.id
        )
        XCTAssertEqual(
            FileTransferDestinationResolver.resolve(
                selectedDeviceID: nil,
                continuityTargetID: controlTarget.id,
                candidates: candidates,
                connectedDeviceIDs: connected
            ),
            controlTarget.id
        )
        XCTAssertEqual(
            FileTransferDestinationResolver.resolve(
                selectedDeviceID: nil,
                continuityTargetID: nil,
                candidates: candidates,
                connectedDeviceIDs: connected
            ),
            fallback.id
        )
    }

    func testResolverNeverReturnsDisconnectedSelectionTargetOrCandidate() {
        let disconnectedSelection = DeviceDescriptor(id: DeviceID(), name: "Selected")
        let disconnectedTarget = DeviceDescriptor(id: DeviceID(), name: "Target")
        let connectedFallback = DeviceDescriptor(id: DeviceID(), name: "Fallback")

        XCTAssertEqual(
            FileTransferDestinationResolver.resolve(
                selectedDeviceID: disconnectedSelection.id,
                continuityTargetID: disconnectedTarget.id,
                candidates: [disconnectedSelection, disconnectedTarget, connectedFallback],
                connectedDeviceIDs: [connectedFallback.id]
            ),
            connectedFallback.id
        )
        XCTAssertNil(FileTransferDestinationResolver.resolve(
            selectedDeviceID: disconnectedSelection.id,
            continuityTargetID: disconnectedTarget.id,
            candidates: [disconnectedSelection, disconnectedTarget],
            connectedDeviceIDs: []
        ))
    }

    func testControlPlaneDestinationCanBootstrapBeforeContentConnectionIsReady() {
        let target = DeviceDescriptor(id: DeviceID(), name: "Fox")

        let desired = FileTransferDestinationResolver.resolve(
            selectedDeviceID: target.id,
            continuityTargetID: target.id,
            candidates: [target],
            connectedDeviceIDs: [target.id]
        )
        let ready = FileTransferDestinationResolver.resolve(
            selectedDeviceID: target.id,
            continuityTargetID: target.id,
            candidates: [target],
            connectedDeviceIDs: []
        )

        XCTAssertEqual(desired, target.id)
        XCTAssertNil(ready)
    }
}
