import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class SimulatedE2ETests: XCTestCase {
    func testTwoMacInputFlowsThroughRealCodecAndReturnsControlCleanly() async throws {
        let workspaceID = WorkspaceID()
        let controllerID = DeviceID()
        let receiverID = DeviceID()
        let receiverDisplay = display(deviceID: receiverID)
        let controllerCapture = SimulatedCapture()
        let receiverInjector = SimulatedInjector()
        let controllerTransport = SimulatedWireTransport(localDeviceID: controllerID)
        let receiverTransport = SimulatedWireTransport(localDeviceID: receiverID)
        let controller = ControlSessionCoordinator(
            localDeviceID: controllerID,
            workspaceID: workspaceID,
            capture: controllerCapture,
            injector: SimulatedInjector(),
            transport: controllerTransport
        )
        let receiver = ControlSessionCoordinator(
            localDeviceID: receiverID,
            workspaceID: workspaceID,
            capture: SimulatedCapture(),
            injector: receiverInjector,
            transport: receiverTransport
        )
        controllerTransport.connect(
            to: receiver,
            display: receiverDisplay,
            responseTransport: receiverTransport
        )
        receiverTransport.connect(to: controller, display: display(deviceID: controllerID))

        let epoch = await controller.makeLocalController()
        await receiver.observeControllerClaim(epoch)
        try await controller.activate(
            target: receiverID,
            displayID: receiverDisplay.id,
            entryEdge: .left,
            normalizedPosition: 0.25,
            targetCapabilities: [.publicTrackpadGestures, .activationAcknowledgementV1]
        )

        XCTAssertTrue(controllerCapture.isSuppressionEnabled)
        guard case .receiving = await receiver.currentState() else {
            return XCTFail("The simulated receiver must accept activation")
        }

        let gesture = InputEvent.gesture(serializedEvent: Data([1, 2, 3]))
        _ = await controller.handleCaptured(.flags(rawValue: 0x100))
        _ = await controller.handleCaptured(.key(code: 12, isDown: true, isRepeat: false))
        _ = await controller.handleCaptured(.mouseButton(button: .left, isDown: true, clickCount: 1))
        _ = await controller.handleCaptured(.pointerMove(
            deltaX: 8,
            deltaY: -3,
            absoluteX: 20,
            absoluteY: 30
        ))
        _ = await controller.handleCaptured(.mouseButton(button: .left, isDown: false, clickCount: 1))
        _ = await controller.handleCaptured(.scroll(deltaX: 2, deltaY: -5, isContinuous: true))
        _ = await controller.handleCaptured(gesture)
        await controller.deactivateCurrentSession()

        XCTAssertEqual(receiverInjector.activations, [
            .init(displayID: receiverDisplay.id, edge: .left, position: 0.25)
        ])
        XCTAssertTrue(receiverInjector.events.contains(.flags(rawValue: 0x100)))
        XCTAssertTrue(receiverInjector.events.contains(.key(code: 12, isDown: true, isRepeat: false)))
        XCTAssertTrue(receiverInjector.events.contains(.pointerMove(
            deltaX: 8,
            deltaY: -3,
            absoluteX: 20,
            absoluteY: 30
        )))
        XCTAssertTrue(receiverInjector.events.contains(.scroll(deltaX: 2, deltaY: -5, isContinuous: true)))
        XCTAssertTrue(receiverInjector.events.contains(gesture))
        XCTAssertTrue(receiverInjector.events.contains(.key(code: 12, isDown: false, isRepeat: false)))
        XCTAssertGreaterThanOrEqual(receiverInjector.releaseAllCount, 1)
        XCTAssertFalse(controllerCapture.isSuppressionEnabled)
        let controllerState = await controller.currentState()
        let receiverState = await receiver.currentState()
        XCTAssertEqual(controllerState, .idle)
        XCTAssertEqual(receiverState, .idle)
        await controller.stop()
        await receiver.stop()
    }

    func testMixedVersionPeerSkipsOnlyGestureFrames() async throws {
        let workspaceID = WorkspaceID()
        let controllerID = DeviceID()
        let receiverID = DeviceID()
        let receiverInjector = SimulatedInjector()
        let transport = SimulatedWireTransport(localDeviceID: controllerID)
        let controller = ControlSessionCoordinator(
            localDeviceID: controllerID,
            workspaceID: workspaceID,
            capture: SimulatedCapture(),
            injector: SimulatedInjector(),
            transport: transport
        )
        let receiver = ControlSessionCoordinator(
            localDeviceID: receiverID,
            workspaceID: workspaceID,
            capture: SimulatedCapture(),
            injector: receiverInjector,
            transport: SimulatedWireTransport(localDeviceID: receiverID)
        )
        let targetDisplay = display(deviceID: receiverID)
        transport.connect(to: receiver, display: targetDisplay)
        let epoch = await controller.makeLocalController()
        await receiver.observeControllerClaim(epoch)
        try await controller.activate(
            target: receiverID,
            displayID: targetDisplay.id,
            entryEdge: .right,
            normalizedPosition: 0.5,
            targetCapabilities: []
        )

        _ = await controller.handleCaptured(.gesture(serializedEvent: Data([9, 9])))
        _ = await controller.handleCaptured(.key(code: 1, isDown: true, isRepeat: false))
        await controller.flushPendingInput()

        XCTAssertFalse(receiverInjector.events.contains { event in
            if case .gesture = event { return true }
            return false
        })
        XCTAssertTrue(receiverInjector.events.contains(.key(code: 1, isDown: true, isRepeat: false)))
        await controller.stop()
        await receiver.stop()
    }

    func testThreeMacElectionConvergesAndOnlyWinnerCanActivate() async throws {
        let workspaceID = WorkspaceID()
        let firstID = DeviceID()
        let secondID = DeviceID()
        let receiverID = DeviceID()
        let receiver = ControlSessionCoordinator(
            localDeviceID: receiverID,
            workspaceID: workspaceID,
            capture: SimulatedCapture(),
            injector: SimulatedInjector(),
            transport: SimulatedWireTransport(localDeviceID: receiverID)
        )
        let firstTransport = SimulatedWireTransport(localDeviceID: firstID)
        let secondTransport = SimulatedWireTransport(localDeviceID: secondID)
        let first = ControlSessionCoordinator(
            localDeviceID: firstID,
            workspaceID: workspaceID,
            capture: SimulatedCapture(),
            injector: SimulatedInjector(),
            transport: firstTransport
        )
        let second = ControlSessionCoordinator(
            localDeviceID: secondID,
            workspaceID: workspaceID,
            capture: SimulatedCapture(),
            injector: SimulatedInjector(),
            transport: secondTransport
        )
        let target = display(deviceID: receiverID)
        firstTransport.connect(to: receiver, display: target)
        secondTransport.connect(to: receiver, display: target)
        let losingEpoch = ControllerEpoch(generation: 3, controllerID: firstID)
        let winningEpoch = ControllerEpoch(generation: 4, controllerID: secondID)
        for coordinator in [first, second, receiver] {
            await coordinator.observeControllerClaim(losingEpoch)
            await coordinator.observeControllerClaim(winningEpoch)
        }

        try await first.activate(
            target: receiverID,
            displayID: target.id,
            entryEdge: .left,
            normalizedPosition: 0.5
        )
        let firstState = await first.currentState()
        XCTAssertEqual(firstState, .idle)

        try await second.activate(
            target: receiverID,
            displayID: target.id,
            entryEdge: .left,
            normalizedPosition: 0.5
        )
        guard case let .receiving(epoch, source, _) = await receiver.currentState() else {
            return XCTFail("Receiver must accept the winning controller")
        }
        XCTAssertEqual(epoch, winningEpoch)
        XCTAssertEqual(source, secondID)
        await first.stop()
        await second.stop()
        await receiver.stop()
    }

    private func display(deviceID: DeviceID) -> DisplayDescriptor {
        .init(
            id: DisplayID(),
            deviceID: deviceID,
            name: "Display",
            frame: .init(x: 0, y: 0, width: 100, height: 100),
            scaleFactor: 2,
            isMain: true
        )
    }
}

private final class SimulatedWireTransport: PeerTransport, @unchecked Sendable {
    typealias Connection = (
        coordinator: ControlSessionCoordinator,
        display: DisplayDescriptor,
        responseTransport: SimulatedWireTransport?
    )

    private let localDeviceID: DeviceID
    private let lock = NSLock()
    private var connection: Connection?
    private let stream = AsyncStream<PeerEvent> { $0.finish() }

    init(localDeviceID: DeviceID) {
        self.localDeviceID = localDeviceID
    }

    func connect(
        to coordinator: ControlSessionCoordinator,
        display: DisplayDescriptor,
        responseTransport: SimulatedWireTransport? = nil
    ) {
        lock.withLock {
            connection = (coordinator, display, responseTransport)
        }
    }

    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func reconnect(to deviceID: DeviceID) {}
    func events() -> AsyncStream<PeerEvent> { stream }

    func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws {
        let encoded = try WireFrameCodec.encodeControl(envelope)
        let (kind, payload) = try WireFrameCodec.decode(encoded)
        guard kind == .controlJSON, let connection = lock.withLock({ connection }) else { return }
        let decoded = try WireFrameCodec.decodeControl(payload)
        switch decoded.message {
        case let .controllerClaim(epoch):
            await connection.coordinator.observeControllerClaim(epoch)
        case let .activate(activation):
            let accepted = await connection.coordinator.receiveActivation(
                activation,
                from: localDeviceID,
                targetDisplay: connection.display
            )
            if let responseTransport = connection.responseTransport {
                try await responseTransport.send(
                    ControlEnvelope(message: .activationResult(
                        sessionID: activation.sessionID,
                        accepted: accepted
                    )),
                    to: localDeviceID
                )
            }
        case let .activationResult(sessionID, accepted):
            _ = await connection.coordinator.receiveActivationResult(
                sessionID: sessionID,
                from: localDeviceID,
                accepted: accepted
            )
        case .deactivate, .releaseAll:
            await connection.coordinator.deactivateCurrentSession()
        case let .heartbeat(sessionID, _):
            _ = await connection.coordinator.receiveHeartbeat(sessionID: sessionID, from: localDeviceID)
        case .hello, .workspace, .boundaryCrossed, .rotateWorkspaceKey:
            break
        }
    }

    func send(_ frame: InputFrame, to deviceID: DeviceID) async throws {
        let encoded = try WireFrameCodec.encodeInput(frame)
        let (kind, payload) = try WireFrameCodec.decode(encoded)
        guard kind == .inputBinary, let connection = lock.withLock({ connection }) else { return }
        await connection.coordinator.handleIncoming(
            try WireFrameCodec.decodeInput(payload),
            from: localDeviceID
        )
    }

    func sendRealtime(_ frame: RealtimePointerFrame, to deviceID: DeviceID) async throws -> Bool {
        let encoded = try WireFrameCodec.encodeRealtimePointer(frame)
        let (kind, payload) = try WireFrameCodec.decode(encoded)
        guard kind == .realtimePointerBinary, let connection = lock.withLock({ connection }) else {
            return false
        }
        await connection.coordinator.handleIncomingRealtime(
            try WireFrameCodec.decodeRealtimePointer(payload),
            from: localDeviceID
        )
        return true
    }
}

private final class SimulatedCapture: InputCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var suppressed = false
    var isSuppressionEnabled: Bool { lock.withLock { suppressed } }
    func start(handler: @escaping @Sendable (InputEvent) -> Bool) throws {}
    func stop() {}
    func setSuppressionEnabled(_ enabled: Bool) { lock.withLock { suppressed = enabled } }
}

private final class SimulatedInjector: InputInjector, @unchecked Sendable {
    struct Activation: Equatable {
        let displayID: DisplayID
        let edge: DisplayEdge
        let position: Double
    }

    private let lock = NSLock()
    private var storedEvents: [InputEvent] = []
    private var storedActivations: [Activation] = []
    private var storedReleaseAllCount = 0
    var events: [InputEvent] { lock.withLock { storedEvents } }
    var activations: [Activation] { lock.withLock { storedActivations } }
    var releaseAllCount: Int { lock.withLock { storedReleaseAllCount } }

    func activate(on display: DisplayDescriptor, enteringFrom edge: DisplayEdge, normalizedPosition: Double) {
        lock.withLock {
            storedActivations.append(.init(displayID: display.id, edge: edge, position: normalizedPosition))
        }
    }

    func inject(_ event: InputEvent) { lock.withLock { storedEvents.append(event) } }
    func releaseAll() { lock.withLock { storedReleaseAllCount += 1 } }
}
