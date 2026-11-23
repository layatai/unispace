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

    // Regression: "Forget Device" removed the device locally, but the next
    // snapshot from a peer that still listed it unioned it straight back.
    func testForgottenDeviceIsNotResurrectedByStalePeerSnapshot() throws {
        let fixture = ForgetFixture()
        var current = fixture.snapshot(localDeviceID: fixture.localID, devices: [fixture.local, fixture.peer, fixture.forgotten])
        current.forget(fixture.forgottenID, stamp: 1_000)
        let stale = fixture.snapshot(localDeviceID: fixture.peerID, devices: [fixture.local, fixture.peer, fixture.forgotten])

        let merged = try XCTUnwrap(WorkspaceReplicaMerger.mergeSnapshot(current, with: stale))

        XCTAssertEqual(Set(merged.devices.map(\.id)), [fixture.localID, fixture.peerID])
        XCTAssertTrue(merged.isForgotten(fixture.forgottenID))
    }

    func testForgetPropagatesToPeerReplicaThatStillListsTheDevice() throws {
        let fixture = ForgetFixture()
        var origin = fixture.snapshot(localDeviceID: fixture.localID, devices: [fixture.local, fixture.peer, fixture.forgotten])
        origin.forget(fixture.forgottenID, stamp: 1_000)
        let peerReplica = fixture.snapshot(localDeviceID: fixture.peerID, devices: [fixture.local, fixture.peer, fixture.forgotten])

        let merged = try XCTUnwrap(WorkspaceReplicaMerger.mergeSnapshot(peerReplica, with: origin))

        XCTAssertFalse(merged.devices.contains { $0.id == fixture.forgottenID })
    }

    func testPairingAgainAfterForgetWinsOverOlderTombstone() throws {
        let fixture = ForgetFixture()
        var stalePeer = fixture.snapshot(localDeviceID: fixture.peerID, devices: [fixture.local, fixture.peer])
        stalePeer.record(DeviceMembershipChange(deviceID: fixture.forgottenID, removed: true, stamp: 1_000))
        var host = fixture.snapshot(localDeviceID: fixture.localID, devices: [fixture.local, fixture.peer])
        host.record(DeviceMembershipChange(deviceID: fixture.forgottenID, removed: true, stamp: 1_000))
        host.admit(fixture.forgotten, stamp: 2_000)

        let onHost = try XCTUnwrap(WorkspaceReplicaMerger.mergeSnapshot(host, with: stalePeer))
        let onPeer = try XCTUnwrap(WorkspaceReplicaMerger.mergeSnapshot(stalePeer, with: host))

        XCTAssertTrue(onHost.devices.contains { $0.id == fixture.forgottenID })
        XCTAssertTrue(onPeer.devices.contains { $0.id == fixture.forgottenID })
        XCTAssertFalse(onPeer.isForgotten(fixture.forgottenID))
    }

    func testSnapshotsWithoutMembershipChangesStillDecode() throws {
        let fixture = ForgetFixture()
        let snapshot = fixture.snapshot(localDeviceID: fixture.localID, devices: [fixture.local])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "membershipChanges")

        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(decoded, snapshot)
    }
}

private struct ForgetFixture {
    let workspaceID = WorkspaceID()
    let localID = DeviceID()
    let peerID = DeviceID()
    let forgottenID = DeviceID()
    var local: DeviceDescriptor { DeviceDescriptor(id: localID, name: "Local", platform: .macOS) }
    var peer: DeviceDescriptor { DeviceDescriptor(id: peerID, name: "Peer", platform: .macOS) }
    var forgotten: DeviceDescriptor { DeviceDescriptor(id: forgottenID, name: "Forgotten PC", platform: .windows) }

    func snapshot(localDeviceID: DeviceID, devices: [DeviceDescriptor]) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: workspaceID, name: "Workspace", localDeviceID: localDeviceID, devices: devices, generation: 5)
    }
}
