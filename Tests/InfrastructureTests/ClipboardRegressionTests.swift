import AppKit
import Network
import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain
@testable import UniSpaceInfrastructure

/// Regression: cross-machine copy and paste between two Macs while no control
/// session is active, in a workspace that also lists offline Linux and Windows
/// peers. Exercises the real coordinators, encrypted transports and
/// pasteboard services on private named pasteboards (never the general one).
@MainActor
final class ClipboardRegressionTests: XCTestCase {
    func testIdleMacsSyncTextInBothDirectionsWithOfflinePeersInWorkspace() async throws {
        let workspaceID = WorkspaceID()
        let key = PairingCryptoSession.randomData(count: 32)
        let clipboardCapabilities: Set<DeviceCapability> = [.clipboardTextV1, .clipboardURLV1]
        // The smaller device ID owns the dial, so "dialer" connects to "listener".
        let dialer = DeviceDescriptor(
            id: DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!),
            name: "Dialer Mac", capabilities: clipboardCapabilities, platform: .macOS
        )
        let listener = DeviceDescriptor(
            id: DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!),
            name: "Listener Mac", capabilities: clipboardCapabilities, platform: .macOS
        )
        let offline: [DeviceDescriptor] = [
            .init(id: DeviceID(), name: "Offline Linux", capabilities: clipboardCapabilities, platform: .linux),
            .init(id: DeviceID(), name: "Offline Windows", capabilities: [.crossPlatformInputV2], platform: .windows),
        ]

        let listenerPasteboard = NSPasteboard(name: .init("UniSpace-regression-\(UUID())"))
        let dialerPasteboard = NSPasteboard(name: .init("UniSpace-regression-\(UUID())"))
        defer {
            listenerPasteboard.releaseGlobally()
            dialerPasteboard.releaseGlobally()
        }

        let listenerTransport = NetworkClipboardTransport(listenPort: .any, directPort: .any, enableBonjour: false)
        let listenerCoordinator = ClipboardCoordinator(
            transport: listenerTransport,
            clipboard: SystemClipboardService(pasteboard: listenerPasteboard, pollingInterval: .milliseconds(10))
        )
        try await listenerCoordinator.start(
            localDevice: listener,
            workspace: WorkspaceSnapshot(id: workspaceID, name: "Regression", localDeviceID: listener.id,
                                         devices: [dialer, listener] + offline),
            key: key
        )
        await listenerCoordinator.setSharingEnabled(true)
        await listenerCoordinator.setAutomaticDestination(dialer.id)
        let port = try await waitForPort(listenerTransport)

        let routedListener = DeviceDescriptor(
            id: listener.id, name: listener.name, peerAddresses: [try PeerAddress("127.0.0.1")],
            capabilities: clipboardCapabilities, platform: .macOS
        )
        let dialerCoordinator = ClipboardCoordinator(
            transport: NetworkClipboardTransport(listenPort: .any, directPort: port, enableBonjour: false),
            clipboard: SystemClipboardService(pasteboard: dialerPasteboard, pollingInterval: .milliseconds(10))
        )
        try await dialerCoordinator.start(
            localDevice: dialer,
            workspace: WorkspaceSnapshot(id: workspaceID, name: "Regression", localDeviceID: dialer.id,
                                         devices: [dialer, routedListener] + offline),
            key: key
        )
        await dialerCoordinator.setSharingEnabled(true)
        await dialerCoordinator.setAutomaticDestination(listener.id)

        let connected = await eventually {
            let dialerPeers = await dialerCoordinator.connectedDeviceIDs()
            let listenerPeers = await listenerCoordinator.connectedDeviceIDs()
            return dialerPeers.contains(listener.id) && listenerPeers.contains(dialer.id)
        }
        XCTAssertTrue(connected, "Idle Macs must hold an encrypted clipboard connection")

        let outbound = "regression-outbound-\(UUID())"
        write(outbound, to: dialerPasteboard)
        let delivered = await eventually { listenerPasteboard.string(forType: .string) == outbound }
        XCTAssertTrue(delivered, "Text copied on the dialing Mac must arrive on the listening Mac")

        let inbound = "regression-inbound-\(UUID())"
        write(inbound, to: listenerPasteboard)
        let returned = await eventually { dialerPasteboard.string(forType: .string) == inbound }
        XCTAssertTrue(returned, "Text copied on the listening Mac must arrive on the dialing Mac")

        await dialerCoordinator.stop()
        await listenerCoordinator.stop()
    }

    private func write(_ value: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func waitForPort(_ transport: NetworkClipboardTransport) async throws -> NWEndpoint.Port {
        for _ in 0..<200 {
            if let port = transport.activePort { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NetworkClipboardError.invalidConfiguration
    }
}
