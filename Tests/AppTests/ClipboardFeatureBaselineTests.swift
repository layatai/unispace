import Foundation
import Testing
import UniSpaceApplication
import UniSpaceDomain

/// Runs the actual app view model and coordinator without launching the app,
/// changing the general pasteboard, or opening production network listeners.
@MainActor
struct ClipboardFeatureBaselineTests {
    @Test(arguments: [false, true])
    func samePeerSurvivesWorkspaceRefresh(keyRotation: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.refresh()
        #expect(await fixture.coordinator.automaticDestinationDeviceID() == fixture.peer.id)
        if keyRotation {
            fixture.rotateKey()
        } else {
            fixture.peer.name = "Renamed peer"
            fixture.workspace.updateDevice(fixture.peer)
        }
        await fixture.refresh()
        #expect(fixture.transport.startCount == 2)
        #expect(fixture.model.activeDestinationID == fixture.peer.id)
        #expect(await fixture.coordinator.automaticDestinationDeviceID() == fixture.peer.id)
        #expect(fixture.transport.desiredPeer == fixture.peer.id)
        await fixture.coordinator.stop()
    }

    @Test
    func unchangedContextDoesNotRestartTransport() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.refresh()
        await fixture.refresh()
        #expect(fixture.transport.startCount == 1)
        #expect(fixture.transport.desiredPeer == fixture.peer.id)
        await fixture.coordinator.stop()
    }

    @Test
    func disabledSharingNeverDialsAfterRefresh() async {
        let fixture = Fixture(sharing: false)
        defer { fixture.cleanUp() }
        await fixture.refresh()
        fixture.rotateKey()
        await fixture.refresh()
        #expect(fixture.transport.startCount == 2)
        #expect(fixture.transport.desiredPeer == nil)
        #expect(await fixture.coordinator.isSharingEnabled() == false)
        await fixture.coordinator.stop()
    }

    /// Regression (build 46): with a second clipboard-capable peer online (a
    /// Linux receiver), an idle workspace refresh restarted the coordinator,
    /// cleared its destination, and the resolver had no unambiguous choice, so
    /// both Macs stopped dialing and rejected each other's clipboard channel.
    @Test
    func routeSurvivesRefreshWhileAnotherCompatiblePeerIsOnline() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let linux = DeviceDescriptor(id: DeviceID(), name: "Linux receiver",
                                     capabilities: [.clipboardTextV1], platform: .linux)
        fixture.workspace.updateDevice(linux)
        // A control session with the Mac peer establishes the route.
        await fixture.refresh(connected: [fixture.peer.id],
                              session: .init(phase: .controlling, peerID: fixture.peer.id))
        #expect(fixture.transport.desiredPeer == fixture.peer.id)
        // The session ends and the Linux receiver comes online: still the Mac.
        await fixture.refresh(connected: [fixture.peer.id, linux.id])
        #expect(fixture.transport.desiredPeer == fixture.peer.id)
        // A workspace update (presence, addresses, displays) restarts the
        // coordinator; the established route must survive it.
        fixture.peer.name = "Peer with new presence"
        fixture.workspace.updateDevice(fixture.peer)
        await fixture.refresh(connected: [fixture.peer.id, linux.id])
        #expect(fixture.transport.startCount == 2)
        #expect(fixture.model.activeDestinationID == fixture.peer.id)
        #expect(fixture.transport.desiredPeer == fixture.peer.id)
        await fixture.coordinator.stop()
    }

    @Test
    func rememberedRouteIsDroppedWhenItsPeerLeavesTheWorkspace() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let linux = DeviceDescriptor(id: DeviceID(), name: "Linux receiver",
                                     capabilities: [.clipboardTextV1], platform: .linux)
        fixture.workspace.updateDevice(linux)
        await fixture.refresh(connected: [fixture.peer.id],
                              session: .init(phase: .controlling, peerID: fixture.peer.id))
        fixture.workspace.devices.removeAll { $0.id == fixture.peer.id }
        await fixture.refresh(connected: [linux.id])
        #expect(fixture.model.activeDestinationID == linux.id, "The only remaining candidate takes over")
        #expect(fixture.transport.desiredPeer == linux.id)
        await fixture.coordinator.stop()
    }

    @Test
    func leavingWorkspaceClearsDestination() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.refresh()
        await fixture.model.refreshContext(.init(workspace: nil, connectedDeviceIDs: [],
            controllerID: nil, controlSession: .idle, workspaceKeyRevision: 0), localDevice: fixture.local)
        #expect(fixture.model.activeDestinationID == nil)
        #expect(fixture.transport.desiredPeer == nil)
        #expect(await fixture.coordinator.automaticDestinationDeviceID() == nil)
    }
}

@MainActor
private final class Fixture {
    let local = DeviceDescriptor(id: DeviceID(), name: "Controller", capabilities: [.clipboardTextV1])
    var peer = DeviceDescriptor(id: DeviceID(), name: "Receiver", capabilities: [.clipboardTextV1])
    var workspace: WorkspaceSnapshot
    var revision: UInt64 = 0
    let suite = "UniSpace.clipboard-baseline.\(UUID().uuidString)"
    let defaults: UserDefaults
    let transport = BaselineClipboardTransport()
    let trust = BaselineTrust()
    let coordinator: ClipboardCoordinator
    let model: ClipboardViewModel

    init(sharing: Bool = true) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(sharing, forKey: "continuity.clipboardSharingEnabled")
        workspace = WorkspaceSnapshot(id: WorkspaceID(), name: "Baseline", localDeviceID: local.id,
                                      devices: [local, peer])
        coordinator = ClipboardCoordinator(transport: transport, clipboard: BaselineClipboard())
        model = ClipboardViewModel(defaults: defaults, trustStore: trust, coordinator: coordinator)
    }

    func refresh() async {
        await refresh(connected: [peer.id])
    }

    func refresh(connected: Set<DeviceID>, session: ControlSessionSnapshot = .idle) async {
        await model.refreshContext(.init(workspace: workspace, connectedDeviceIDs: connected,
            controllerID: local.id, controlSession: session, workspaceKeyRevision: revision), localDevice: local)
    }

    func rotateKey() { revision += 1; trust.rotate() }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

private final class BaselineTrust: TrustStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key = Data(repeating: 1, count: 32)
    func rotate() { lock.withLock { key = Data(repeating: 2, count: 32) } }
    func workspaceKey(for workspaceID: WorkspaceID) throws -> Data? { lock.withLock { key } }
    func storeWorkspaceKey(_ key: Data, for workspaceID: WorkspaceID) throws {}
    func removeWorkspaceKey(for workspaceID: WorkspaceID) throws {}
}

private final class BaselineClipboardTransport: ClipboardTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var desired: DeviceID?
    private let channel = AsyncStream<ClipboardTransportEvent>.makeStream()
    var startCount: Int { lock.withLock { starts } }
    var desiredPeer: DeviceID? { lock.withLock { desired } }
    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {
        lock.withLock { starts += 1; desired = nil }
    }
    func stop() async { lock.withLock { desired = nil } }
    func setDesiredPeer(_ deviceID: DeviceID?) { lock.withLock { desired = deviceID } }
    func events() -> AsyncStream<ClipboardTransportEvent> { channel.stream }
    func send(_ envelope: ClipboardEnvelope, to deviceID: DeviceID) async throws {}
}

@MainActor
private final class BaselineClipboard: ClipboardService {
    private let channel = AsyncStream<ClipboardObservation>.makeStream()
    func events() -> AsyncStream<ClipboardObservation> { channel.stream }
    func stop() {}
    func apply(_ payload: ClipboardPayload) {}
}
