import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class ApplicationTests: XCTestCase {
    func testEdgeRouterMapsToRemoteDisplayAndNormalizesPosition() {
        let localID = DeviceID()
        let remoteID = DeviceID()
        let localDisplay = display(device: localID, frame: .init(x: 0, y: 0, width: 100, height: 100))
        let remoteDisplay = display(device: remoteID, frame: .init(x: 0, y: 0, width: 200, height: 100))
        var topology = DisplayTopology()
        topology.connect(
            .init(displayID: localDisplay.id, edge: .right),
            to: .init(displayID: remoteDisplay.id, edge: .left)
        )

        let transition = EdgeRouter.transition(
            x: 100,
            y: 25,
            localDeviceID: localID,
            devices: [
                .init(id: localID, name: "Local", displays: [localDisplay]),
                .init(id: remoteID, name: "Remote", displays: [remoteDisplay])
            ],
            topology: topology
        )

        XCTAssertEqual(transition?.targetDeviceID, remoteID)
        XCTAssertEqual(transition?.targetDisplayID, remoteDisplay.id)
        XCTAssertEqual(transition?.entryEdge, .left)
        XCTAssertEqual(transition?.normalizedPosition, 0.25)
    }

    func testWireCodecRoundTripsControlAndInputFrames() throws {
        let device = DeviceID()
        let envelope = ControlEnvelope(message: .controllerClaim(.init(generation: 7, controllerID: device)))
        let encodedControl = try WireFrameCodec.encodeControl(envelope)
        let (controlKind, controlPayload) = try WireFrameCodec.decode(encodedControl)
        XCTAssertEqual(controlKind, .controlJSON)
        XCTAssertEqual(try WireFrameCodec.decodeControl(controlPayload), envelope)

        let epoch = ControllerEpoch(generation: 7, controllerID: device)
        let frame = InputFrame(
            workspaceID: WorkspaceID(),
            sessionID: SessionID(),
            controllerID: device,
            epoch: epoch,
            sequence: 12,
            timestampNanos: 99,
            event: .pointerMove(deltaX: 2, deltaY: -1, absoluteX: 40, absoluteY: 80)
        )
        let encodedInput = try WireFrameCodec.encodeInput(frame)
        let (inputKind, inputPayload) = try WireFrameCodec.decode(encodedInput)
        XCTAssertEqual(inputKind, .inputBinary)
        XCTAssertEqual(try WireFrameCodec.decodeInput(inputPayload), frame)
    }

    func testWireCodecRejectsMismatchedLength() throws {
        var data = try WireFrameCodec.encodeControl(.init(message: .hello(.init(id: DeviceID(), name: "Mac"))))
        data.removeLast()
        XCTAssertThrowsError(try WireFrameCodec.decode(data))
    }

    func testCoordinatorRejectsStaleInputAndReleasesOnDisconnect() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let injector = InjectorSpy()
        let transport = TransportSpy()
        let workspace = WorkspaceID()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: workspace,
            capture: capture,
            injector: injector,
            transport: transport
        )
        let epoch = ControllerEpoch(generation: 2, controllerID: remote)
        await coordinator.observeControllerClaim(epoch)
        let activation = InputActivation(
            sessionID: SessionID(), epoch: epoch, targetDisplayID: DisplayID(), entryEdge: .left, normalizedPosition: 0.5
        )
        await coordinator.receiveActivation(activation, from: remote, targetDisplay: nil)

        let stale = InputFrame(
            workspaceID: workspace,
            sessionID: activation.sessionID,
            controllerID: remote,
            epoch: .init(generation: 1, controllerID: remote),
            sequence: 0,
            timestampNanos: 1,
            event: .key(code: 3, isDown: true, isRepeat: false)
        )
        await coordinator.handleIncoming(stale, from: remote)
        XCTAssertTrue(injector.events.isEmpty)

        let valid = InputFrame(
            workspaceID: workspace,
            sessionID: activation.sessionID,
            controllerID: remote,
            epoch: epoch,
            sequence: 1,
            timestampNanos: 2,
            event: .key(code: 3, isDown: true, isRepeat: false)
        )
        await coordinator.handleIncoming(valid, from: remote)
        XCTAssertEqual(injector.events, [.key(code: 3, isDown: true, isRepeat: false)])

        await coordinator.peerDisconnected(remote)
        XCTAssertTrue(injector.events.contains(.key(code: 3, isDown: false, isRepeat: false)))
        XCTAssertEqual(injector.releaseAllCount, 1)
    }

    func testCoordinatorCoalescesPointerMovesWithoutDroppingFinalPosition() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let transport = TransportSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: CaptureSpy(),
            injector: InjectorSpy(),
            transport: transport
        )
        _ = await coordinator.makeLocalController()
        try await coordinator.activate(
            target: remote,
            displayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5
        )

        _ = await coordinator.handleCaptured(.pointerMove(deltaX: 1, deltaY: 2, absoluteX: 10, absoluteY: 20))
        _ = await coordinator.handleCaptured(.pointerMove(deltaX: 3, deltaY: 4, absoluteX: 13, absoluteY: 24))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(transport.frames.count, 1)
        XCTAssertEqual(
            transport.frames.first?.event,
            .pointerMove(deltaX: 4, deltaY: 6, absoluteX: 13, absoluteY: 24)
        )
        await coordinator.stop()
    }

    private func display(device: DeviceID, frame: DisplayRect) -> DisplayDescriptor {
        .init(id: DisplayID(), deviceID: device, name: "Display", frame: frame, scaleFactor: 2, isMain: true)
    }
}

private final class CaptureSpy: InputCapture, @unchecked Sendable {
    private(set) var suppressed = false
    func start(handler: @escaping @Sendable (InputEvent) -> Bool) throws {}
    func stop() {}
    func setSuppressionEnabled(_ enabled: Bool) { suppressed = enabled }
}

private final class InjectorSpy: InputInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [InputEvent] = []
    private var storedReleaseCount = 0
    var events: [InputEvent] { lock.withLock { storedEvents } }
    var releaseAllCount: Int { lock.withLock { storedReleaseCount } }
    func activate(on display: DisplayDescriptor, enteringFrom edge: DisplayEdge, normalizedPosition: Double) {}
    func inject(_ event: InputEvent) { lock.withLock { storedEvents.append(event) } }
    func releaseAll() { lock.withLock { storedReleaseCount += 1 } }
}

private final class TransportSpy: PeerTransport, @unchecked Sendable {
    private let stream = AsyncStream<PeerEvent> { $0.finish() }
    private let lock = NSLock()
    private var storedFrames: [InputFrame] = []
    var frames: [InputFrame] { lock.withLock { storedFrames } }
    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func events() -> AsyncStream<PeerEvent> { stream }
    func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws {}
    func send(_ frame: InputFrame, to deviceID: DeviceID) async throws {
        lock.withLock { storedFrames.append(frame) }
    }
}
