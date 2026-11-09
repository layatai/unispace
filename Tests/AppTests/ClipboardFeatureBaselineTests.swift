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
        await model.refreshContext(.init(workspace: workspace, connectedDeviceIDs: [peer.id],
            controllerID: local.id, controlSession: .idle, workspaceKeyRevision: revision), localDevice: local)
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
