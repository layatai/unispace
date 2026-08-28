import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class WorkspaceReplicaMergerTests: XCTestCase {
    func testSnapshotMergePreservesDevicesMissingFromPeerReplica() throws {
        let workspaceID = WorkspaceID()
        let localID = DeviceID()
        let windowsID = DeviceID()
        let legacyMacID = DeviceID()
        let local = DeviceDescriptor(id: localID, name: "Local", platform: .macOS)
        let windows = DeviceDescriptor(
            id: windowsID,
            name: "Windows PC",
            peerAddresses: [try PeerAddress("windows.tailnet.ts.net")],
            capabilities: [.crossPlatformInputV2, .quicStreamV2, .udpPointerV2],
            platform: .windows
        )
        let current = WorkspaceSnapshot(
            id: workspaceID,
            name: "Workspace",
            localDeviceID: localID,
            devices: [local, windows],
            generation: 20
        )
        let incoming = WorkspaceSnapshot(
            id: workspaceID,
            name: "Stale peer replica",
            localDeviceID: legacyMacID,
            devices: [
                DeviceDescriptor(id: localID, name: "Local", platform: .macOS),
                DeviceDescriptor(id: legacyMacID, name: "Legacy Mac", platform: .macOS)
            ],
            generation: 19
        )

        let merged = try XCTUnwrap(WorkspaceReplicaMerger.mergeSnapshot(current, with: incoming))

        XCTAssertEqual(Set(merged.devices.map(\.id)), Set([localID, windowsID, legacyMacID]))
        XCTAssertEqual(merged.devices.first(where: { $0.id == windowsID }), windows)
        XCTAssertEqual(merged.generation, 20)
    }

    func testNonAuthoritativeDiscoveryCannotEraseWindowsMetadata() throws {
        let deviceID = DeviceID()
        let current = DeviceDescriptor(
            id: deviceID,
            name: "Windows PC",
            peerAddresses: [try PeerAddress("100.64.0.10")],
            capabilities: [.crossPlatformInputV2, .quicStreamV2, .udpPointerV2],
            platform: .windows
        )
        let discovery = DeviceDescriptor(
            id: deviceID,
            name: "Windows PC",
            peerAddresses: [try PeerAddress("windows.local")]
        )

        let merged = WorkspaceReplicaMerger.mergeDevice(
            current,
            with: discovery,
            capabilitiesAreAuthoritative: false
        )

        XCTAssertEqual(merged.platform, .windows)
        XCTAssertEqual(merged.capabilities, current.capabilities)
        XCTAssertEqual(Set(merged.peerAddresses), Set(current.peerAddresses + discovery.peerAddresses))
    }

    func testAuthoritativeHelloUpgradesLegacyMetadataToWindows() {
        let deviceID = DeviceID()
        let current = DeviceDescriptor(
            id: deviceID,
            name: "Legacy peer",
            capabilities: [.publicTrackpadGestures]
        )
        let hello = DeviceDescriptor(
            id: deviceID,
            name: "Windows PC",
            capabilities: [.crossPlatformInputV2, .quicStreamV2, .udpPointerV2],
            platform: .windows
        )

        let merged = WorkspaceReplicaMerger.mergeDevice(
            current,
            with: hello,
            capabilitiesAreAuthoritative: true
        )

        XCTAssertEqual(merged.platform, .windows)
        XCTAssertEqual(merged.capabilities, hello.capabilities)
    }
}
