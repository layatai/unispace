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

    func testEntryEdgeHysteresisRequiresInwardMovementBeforeReturningThroughEntryEdge() {
        let deviceID = DeviceID()
        let source = display(device: deviceID, frame: .init(x: 0, y: 0, width: 100, height: 100))

        for edge in DisplayEdge.allCases {
            var hysteresis = EntryEdgeHysteresis()
            hysteresis.arm(display: source, entryEdge: edge)
            let transition = EdgeTransition(
                sourceDisplayID: source.id,
                sourceEdge: edge,
                targetDisplayID: DisplayID(),
                targetDeviceID: DeviceID(),
                entryEdge: edge,
                normalizedPosition: 0.5
            )

            XCTAssertFalse(hysteresis.allows(transition), "\(edge) should start guarded")
            let almostInward = inwardPoint(
                for: edge,
                distance: EntryEdgeHysteresis.defaultInwardDistance - 1,
                frame: source.frame
            )
            hysteresis.observe(x: almostInward.x, y: almostInward.y)
            XCTAssertFalse(hysteresis.allows(transition), "\(edge) should remain guarded before the threshold")
            let sufficientlyInward = inwardPoint(
                for: edge,
                distance: EntryEdgeHysteresis.defaultInwardDistance,
                frame: source.frame
            )
            hysteresis.observe(x: sufficientlyInward.x, y: sufficientlyInward.y)
            XCTAssertTrue(hysteresis.allows(transition), "\(edge) should unlock at the threshold")
        }
    }

    func testEntryEdgeHysteresisDoesNotBlockAnotherEdge() {
        let deviceID = DeviceID()
        let source = display(device: deviceID, frame: .init(x: 0, y: 0, width: 100, height: 100))
        var hysteresis = EntryEdgeHysteresis()
        hysteresis.arm(display: source, entryEdge: .right)

        XCTAssertTrue(hysteresis.allows(EdgeTransition(
            sourceDisplayID: source.id,
            sourceEdge: .top,
            targetDisplayID: DisplayID(),
            targetDeviceID: DeviceID(),
            entryEdge: .bottom,
            normalizedPosition: 0.5
        )))
    }

    func testManualStopRejectsStaleActivationAndRearmsTheExitEdge() throws {
        let localID = DeviceID()
        let source = display(device: localID, frame: .init(x: 0, y: 0, width: 100, height: 100))
        let transition = EdgeTransition(
            sourceDisplayID: source.id,
            sourceEdge: .left,
            targetDisplayID: DisplayID(),
            targetDeviceID: DeviceID(),
            entryEdge: .right,
            normalizedPosition: 0.5
        )
        var guardState = ControlTransferGuard()
        let attempt = try XCTUnwrap(guardState.beginActivation(transition, sourceDisplay: source))

        // Remote movement can move the captured absolute point far enough inward
        // to clear the original edge hysteresis while control is active.
        guardState.observe(x: 50, y: 50)
        guardState.beginStop()
        XCTAssertFalse(guardState.allows(transition))
        guardState.completeStop()

        XCTAssertFalse(guardState.activationSucceeded(attempt))
        XCTAssertFalse(guardState.allows(transition))
        guardState.observe(x: EntryEdgeHysteresis.defaultInwardDistance, y: 50)
        XCTAssertTrue(guardState.allows(transition))
    }

    func testStaleActivationCompletionCannotCancelANewerTransfer() throws {
        let localID = DeviceID()
        let source = display(device: localID, frame: .init(x: 0, y: 0, width: 100, height: 100))
        let transition = EdgeTransition(
            sourceDisplayID: source.id,
            sourceEdge: .right,
            targetDisplayID: DisplayID(),
            targetDeviceID: DeviceID(),
            entryEdge: .left,
            normalizedPosition: 0.5
        )
        var guardState = ControlTransferGuard()
        XCTAssertFalse(guardState.forwardsCapturedInput)
        let staleAttempt = try XCTUnwrap(guardState.beginActivation(transition, sourceDisplay: source))
        guardState.beginStop()
        guardState.completeStop()
        guardState.observe(x: source.frame.maxX - EntryEdgeHysteresis.defaultInwardDistance, y: 50)

        let currentAttempt = try XCTUnwrap(guardState.beginActivation(transition, sourceDisplay: source))
        guardState.activationFailed(staleAttempt)

        XCTAssertTrue(guardState.activationSucceeded(currentAttempt))
        XCTAssertTrue(guardState.forwardsCapturedInput)
    }

    func testControlTransferGuardHandlesFailureIdleStopReturnAndReset() throws {
        let localID = DeviceID()
        let source = display(device: localID, frame: .init(x: 0, y: 0, width: 100, height: 100))
        let transition = EdgeTransition(
            sourceDisplayID: source.id,
            sourceEdge: .right,
            targetDisplayID: DisplayID(),
            targetDeviceID: DeviceID(),
            entryEdge: .left,
            normalizedPosition: 0.5
        )
        var guardState = ControlTransferGuard()
        let failedAttempt = try XCTUnwrap(guardState.beginActivation(transition, sourceDisplay: source))
        XCTAssertNil(guardState.beginActivation(transition, sourceDisplay: source))
        guardState.activationFailed(failedAttempt)
        guardState.observe(x: source.frame.maxX - EntryEdgeHysteresis.defaultInwardDistance, y: 50)
        XCTAssertTrue(guardState.allows(transition))

        guardState.beginStop()
        guardState.beginStop()
        XCTAssertFalse(guardState.allows(transition))
        guardState.completeStop()
        guardState.completeStop()
        XCTAssertTrue(guardState.allows(transition))

        guardState.returned(to: source, enteringFrom: .right)
        XCTAssertFalse(guardState.allows(transition))
        guardState.reset()
        XCTAssertTrue(guardState.allows(transition))
    }

    func testReturnFromLeftMacUnlocksAfterShortInwardMoveAndAllowsPointerOvershoot() throws {
        let controllerID = DeviceID()
        let leftMacID = DeviceID()
        let controllerDisplay = display(
            device: controllerID,
            frame: .init(x: 0, y: 0, width: 100, height: 100)
        )
        let leftDisplay = display(
            device: leftMacID,
            frame: .init(x: 0, y: 0, width: 100, height: 100)
        )
        var topology = DisplayTopology()
        topology.connect(
            .init(displayID: leftDisplay.id, edge: .right),
            to: .init(displayID: controllerDisplay.id, edge: .left)
        )
        var hysteresis = EntryEdgeHysteresis()
        hysteresis.arm(display: leftDisplay, entryEdge: .right)

        hysteresis.observe(x: 88, y: 50)
        let transition = try XCTUnwrap(EdgeRouter.transition(
            x: 112,
            y: 50,
            localDeviceID: leftMacID,
            devices: [
                .init(id: controllerID, name: "Controller", displays: [controllerDisplay]),
                .init(id: leftMacID, name: "Left Mac", displays: [leftDisplay])
            ],
            topology: topology
        ))

        XCTAssertTrue(hysteresis.allows(transition))
        XCTAssertEqual(transition.sourceEdge, .right)
        XCTAssertEqual(transition.targetDeviceID, controllerID)
    }

    func testPointerOnAdjacentLocalDisplayDoesNotTriggerOvershotRemoteEdge() {
        let localID = DeviceID()
        let remoteID = DeviceID()
        let firstLocalDisplay = display(
            device: localID,
            frame: .init(x: 0, y: 0, width: 100, height: 100)
        )
        let adjacentLocalDisplay = display(
            device: localID,
            frame: .init(x: 100, y: 0, width: 100, height: 100)
        )
        let remoteDisplay = display(
            device: remoteID,
            frame: .init(x: 0, y: 0, width: 100, height: 100)
        )
        var topology = DisplayTopology()
        topology.connect(
            .init(displayID: firstLocalDisplay.id, edge: .right),
            to: .init(displayID: remoteDisplay.id, edge: .left)
        )

        XCTAssertNil(EdgeRouter.transition(
            x: 112,
            y: 50,
            localDeviceID: localID,
            devices: [
                .init(id: localID, name: "Local", displays: [firstLocalDisplay, adjacentLocalDisplay]),
                .init(id: remoteID, name: "Remote", displays: [remoteDisplay])
            ],
            topology: topology
        ))
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

        let gestureFrame = InputFrame(
            workspaceID: frame.workspaceID,
            sessionID: frame.sessionID,
            controllerID: device,
            epoch: epoch,
            sequence: 13,
            timestampNanos: 100,
            event: .gesture(serializedEvent: Data([0x47, 0x45, 0x53, 0x54]))
        )
        let encodedGesture = try WireFrameCodec.encodeInput(gestureFrame)
        let (_, gesturePayload) = try WireFrameCodec.decode(encodedGesture)
        XCTAssertEqual(try WireFrameCodec.decodeInput(gesturePayload), gestureFrame)

        let realtime = RealtimePointerFrame(
            workspaceID: frame.workspaceID,
            sessionID: frame.sessionID,
            controllerID: device,
            epoch: epoch,
            generation: 2,
            sequence: 4,
            deltaX: 2,
            deltaY: -1,
            cumulativeDeltaX: 7,
            cumulativeDeltaY: -3,
            absoluteX: 40,
            absoluteY: 80,
            timestampNanos: 100
        )
        let encodedRealtime = try WireFrameCodec.encodeRealtimePointer(realtime)
        let (realtimeKind, realtimePayload) = try WireFrameCodec.decode(encodedRealtime)
        XCTAssertEqual(realtimeKind, .realtimePointerBinary)
        XCTAssertEqual(try WireFrameCodec.decodeRealtimePointer(realtimePayload), realtime)
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

    func testRealtimePointerRecoversCumulativeMotionAfterDatagramLoss() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let workspace = WorkspaceID()
        let injector = InjectorSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: workspace,
            capture: CaptureSpy(),
            injector: injector,
            transport: TransportSpy()
        )
        let epoch = ControllerEpoch(generation: 1, controllerID: remote)
        let sessionID = SessionID()
        await coordinator.observeControllerClaim(epoch)
        _ = await coordinator.receiveActivation(
            .init(
                sessionID: sessionID,
                epoch: epoch,
                targetDisplayID: DisplayID(),
                entryEdge: .left,
                normalizedPosition: 0.5
            ),
            from: remote,
            targetDisplay: nil
        )

        await coordinator.handleIncomingRealtime(.init(
            workspaceID: workspace,
            sessionID: sessionID,
            controllerID: remote,
            epoch: epoch,
            generation: 4,
            sequence: 0,
            deltaX: 2,
            deltaY: 1,
            cumulativeDeltaX: 2,
            cumulativeDeltaY: 1,
            absoluteX: 20,
            absoluteY: 10,
            timestampNanos: 1
        ), from: remote)
        await coordinator.handleIncomingRealtime(.init(
            workspaceID: workspace,
            sessionID: sessionID,
            controllerID: remote,
            epoch: epoch,
            generation: 4,
            sequence: 2,
            deltaX: 3,
            deltaY: 2,
            cumulativeDeltaX: 9,
            cumulativeDeltaY: 5,
            absoluteX: 29,
            absoluteY: 15,
            timestampNanos: 3
        ), from: remote)

        XCTAssertEqual(injector.events, [
            .pointerMove(deltaX: 2, deltaY: 1, absoluteX: 20, absoluteY: 10),
            .pointerMove(deltaX: 7, deltaY: 4, absoluteX: 29, absoluteY: 15)
        ])
        await coordinator.stop()
    }

    func testReceiverDoesNotAbandonSessionAfterFourSecondSlowLinkDelay() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let clock = ManualMonotonicClock()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: CaptureSpy(),
            injector: InjectorSpy(),
            transport: TransportSpy(),
            clock: clock
        )
        let epoch = ControllerEpoch(generation: 1, controllerID: remote)
        await coordinator.observeControllerClaim(epoch)
        let activation = InputActivation(
            sessionID: SessionID(),
            epoch: epoch,
            targetDisplayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5
        )
        let accepted = await coordinator.receiveActivation(activation, from: remote, targetDisplay: nil)
        XCTAssertTrue(accepted)

        for _ in 0..<500 where clock.pendingSleepCount == 0 {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(clock.pendingSleepCount, 1)
        clock.advance(by: 4_000_000_000)
        for _ in 0..<500 where clock.pendingSleepCount == 0 {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(clock.pendingSleepCount, 1)

        guard case let .receiving(_, source, session) = await coordinator.currentState() else {
            return XCTFail("A slow but viable link must not expire after the old three-second watchdog")
        }
        XCTAssertEqual(source, remote)
        XCTAssertEqual(session, activation.sessionID)
        await coordinator.stop()
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

    func testPointerMotionUsesRealtimeLaneButDraggingStaysReliable() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let transport = TransportSpy(useRealtime: true)
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

        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 2,
            deltaY: 1,
            absoluteX: 12,
            absoluteY: 11
        ))
        try await Task.sleep(for: .milliseconds(25))
        _ = await coordinator.handleCaptured(.mouseButton(button: .left, isDown: true, clickCount: 1))
        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 5,
            deltaY: 0,
            absoluteX: 17,
            absoluteY: 11
        ))
        await coordinator.flushPendingInput()

        XCTAssertEqual(transport.realtimeFrames.count, 1)
        XCTAssertEqual(transport.realtimeFrames.first?.cumulativeDeltaX, 2)
        XCTAssertEqual(transport.frames.map(\.event), [
            .mouseButton(button: .left, isDown: true, clickCount: 1),
            .pointerMove(deltaX: 5, deltaY: 0, absoluteX: 17, absoluteY: 11)
        ])
        await coordinator.stop()
    }

    func testHeartbeatEchoReportsSmoothedRoundTripLatency() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let clock = ManualMonotonicClock()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: CaptureSpy(),
            injector: InjectorSpy(),
            transport: TransportSpy(),
            clock: clock
        )
        _ = await coordinator.makeLocalController()
        try await coordinator.activate(
            target: remote,
            displayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5
        )
        guard case let .controlling(_, _, sessionID) = await coordinator.currentState() else {
            return XCTFail("Expected an active control session")
        }

        clock.advance(by: 800_000_000)
        let firstLatency = await coordinator.receiveHeartbeatEcho(
            sessionID: sessionID,
            from: remote,
            sentAtNanos: 0
        )
        XCTAssertEqual(firstLatency, 800)
        clock.advance(by: 200_000_000)
        let secondLatency = await coordinator.receiveHeartbeatEcho(
            sessionID: sessionID,
            from: remote,
            sentAtNanos: 800_000_000
        )
        XCTAssertEqual(secondLatency, 725)
        await coordinator.stop()
    }

    func testControllerImmediatelyReturnsFocusWhenActiveTargetDisconnects() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let transport = TransportSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: capture,
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

        await coordinator.peerDisconnected(remote)

        let state = await coordinator.currentState()
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(capture.suppressed)
        let disposition = await coordinator.handleCaptured(.pointerMove(
            deltaX: 20,
            deltaY: 0,
            absoluteX: 40,
            absoluteY: 20
        ))
        XCTAssertEqual(disposition, .ignored)
        XCTAssertTrue(transport.frames.isEmpty)
    }

    func testCoordinatorCoalescesContinuousScrollWithoutLosingDistance() async throws {
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

        _ = await coordinator.handleCaptured(.scroll(deltaX: 1, deltaY: 2, isContinuous: true))
        _ = await coordinator.handleCaptured(.scroll(deltaX: 3, deltaY: 4, isContinuous: true))
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(transport.frames.map(\.event), [
            .scroll(deltaX: 4, deltaY: 6, isContinuous: true)
        ])
        await coordinator.stop()
    }

    func testCoordinatorForwardsGesturesReliablyWithoutCoalescing() async throws {
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
            normalizedPosition: 0.5,
            targetCapabilities: [.publicTrackpadGestures]
        )
        let gesture = InputEvent.gesture(serializedEvent: Data([1, 2, 3]))

        _ = await coordinator.handleCaptured(gesture)
        await coordinator.flushPendingInput()

        XCTAssertEqual(transport.frames.map(\.event), [gesture])
        await coordinator.stop()
    }

    func testCoordinatorSkipsGesturesForLegacyPeerAndKeepsForwardingInput() async throws {
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

        _ = await coordinator.handleCaptured(.gesture(serializedEvent: Data([1, 2, 3])))
        _ = await coordinator.handleCaptured(.key(code: 12, isDown: true, isRepeat: false))
        await coordinator.flushPendingInput()

        XCTAssertEqual(transport.frames.map(\.event), [
            .key(code: 12, isDown: true, isRepeat: false)
        ])
        await coordinator.stop()
    }

    func testCoordinatorForwardsNormalizedGesturesToPortablePeer() async throws {
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
            normalizedPosition: 0.5,
            targetCapabilities: [.portableTrackpadGestures]
        )
        let gesture = InputEvent.gesture(
            serializedEvent: Data([1, 2, 3]),
            portable: PortableGesture(kind: .magnify, phase: .changed, value: 0.1)
        )

        _ = await coordinator.handleCaptured(gesture)
        await coordinator.flushPendingInput()

        XCTAssertEqual(transport.frames.map(\.event), [gesture])
        await coordinator.stop()
    }

    func testControllerDoesNotReturnLocallyAfterSingleInputSendFailure() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let transport = TransportSpy(frameSendError: SpyError.failure)
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: capture,
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

        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 4,
            deltaY: 0,
            absoluteX: 10,
            absoluteY: 10
        ))
        try await Task.sleep(for: .milliseconds(30))

        guard case let .controlling(_, target, _) = await coordinator.currentState() else {
            return XCTFail("A send failure must wait for confirmed transport disconnection")
        }
        XCTAssertEqual(target, remote)
        XCTAssertTrue(capture.suppressed)
        await coordinator.stop()
    }

    func testActivationDoesNotDisablePrearmedInputSuppression() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: capture,
            injector: InjectorSpy(),
            transport: TransportSpy()
        )
        _ = await coordinator.makeLocalController()
        capture.setSuppressionEnabled(true)
        let historyStart = capture.suppressionHistory.count

        try await coordinator.activate(
            target: remote,
            displayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5
        )

        XCTAssertEqual(Array(capture.suppressionHistory.dropFirst(historyStart)), [true])
        XCTAssertTrue(capture.suppressed)
        await coordinator.stop()
    }

    func testEmergencyHotkeyReturnsControlLocallyAndReleasesPeer() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let transport = TransportSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: capture,
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
        XCTAssertTrue(capture.suppressed)

        let flagsResult = await coordinator.handleCaptured(.flags(rawValue: ControlSessionCoordinator.emergencyFlags))
        let escapeResult = await coordinator.handleCaptured(.key(
            code: ControlSessionCoordinator.emergencyKeyCode,
            isDown: true,
            isRepeat: false
        ))
        let finalState = await coordinator.currentState()

        XCTAssertEqual(flagsResult, .forwarded)
        XCTAssertEqual(escapeResult, .emergencyStop)
        XCTAssertEqual(finalState, .idle)
        XCTAssertFalse(capture.suppressed)
        XCTAssertTrue(transport.controlMessages.contains { message in
            if case .releaseAll = message { return true }
            return false
        })
        XCTAssertTrue(transport.controlMessages.contains { message in
            if case .deactivate = message { return true }
            return false
        })
        XCTAssertFalse(transport.frames.contains { frame in
            if case let .key(code, _, _) = frame.event {
                return code == ControlSessionCoordinator.emergencyKeyCode
            }
            return false
        })
    }

    func testLeaveWorkspaceRemovesPersistentStateThenTrustKey() throws {
        let calls = CallRecorder()
        let workspaceStore = WorkspaceStoreSpy(calls: calls)
        let trustStore = TrustStoreSpy(calls: calls)
        let workspaceID = WorkspaceID()

        let result = try WorkspaceLifecycle(
            workspaceStore: workspaceStore,
            trustStore: trustStore
        ).leave(workspaceID: workspaceID)

        XCTAssertEqual(result, .complete)
        XCTAssertEqual(calls.values, ["workspace.remove", "trust.remove"])
        XCTAssertEqual(trustStore.removedWorkspaceID, workspaceID)
    }

    func testLeaveWorkspaceDoesNotRemoveTrustKeyWhenPersistentStateCannotBeRemoved() {
        let calls = CallRecorder()
        let workspaceStore = WorkspaceStoreSpy(calls: calls, removeError: SpyError.failure)
        let trustStore = TrustStoreSpy(calls: calls)

        XCTAssertThrowsError(
            try WorkspaceLifecycle(
                workspaceStore: workspaceStore,
                trustStore: trustStore
            ).leave(workspaceID: WorkspaceID())
        )
        XCTAssertEqual(calls.values, ["workspace.remove"])
        XCTAssertNil(trustStore.removedWorkspaceID)
    }

    func testLeaveWorkspaceReturnsWarningAfterTrustKeyCleanupFailure() throws {
        let calls = CallRecorder()
        let workspaceStore = WorkspaceStoreSpy(calls: calls)
        let trustStore = TrustStoreSpy(calls: calls, removeError: SpyError.failure)

        let result = try WorkspaceLifecycle(
            workspaceStore: workspaceStore,
            trustStore: trustStore
        ).leave(workspaceID: WorkspaceID())

        XCTAssertEqual(result, .trustKeyCleanupFailed)
        XCTAssertEqual(calls.values, ["workspace.remove", "trust.remove"])
    }

    private func display(device: DeviceID, frame: DisplayRect) -> DisplayDescriptor {
        .init(id: DisplayID(), deviceID: device, name: "Display", frame: frame, scaleFactor: 2, isMain: true)
    }

    private func inwardPoint(for edge: DisplayEdge, distance: Double, frame: DisplayRect) -> (x: Double, y: Double) {
        switch edge {
        case .left: (frame.minX + distance, frame.minY + frame.height / 2)
        case .right: (frame.maxX - distance, frame.minY + frame.height / 2)
        case .bottom: (frame.minX + frame.width / 2, frame.minY + distance)
        case .top: (frame.minX + frame.width / 2, frame.maxY - distance)
        }
    }
}

private enum SpyError: Error {
    case failure
}

private extension ControlMessage {
    var isActivation: Bool {
        if case .activate = self { return true }
        return false
    }
}

private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    var values: [String] { lock.withLock { storedValues } }
    func append(_ value: String) { lock.withLock { storedValues.append(value) } }
}

private final class WorkspaceStoreSpy: WorkspaceStore, @unchecked Sendable {
    private let calls: CallRecorder
    private let removeError: Error?

    init(calls: CallRecorder, removeError: Error? = nil) {
        self.calls = calls
        self.removeError = removeError
    }

    func load() throws -> WorkspaceSnapshot? { nil }
    func save(_ workspace: WorkspaceSnapshot) throws {}
    func remove() throws {
        calls.append("workspace.remove")
        if let removeError { throw removeError }
    }
}

private final class TrustStoreSpy: TrustStore, @unchecked Sendable {
    private let lock = NSLock()
    private let calls: CallRecorder
    private let removeError: Error?
    private var storedRemovedWorkspaceID: WorkspaceID?
    var removedWorkspaceID: WorkspaceID? { lock.withLock { storedRemovedWorkspaceID } }

    init(calls: CallRecorder, removeError: Error? = nil) {
        self.calls = calls
        self.removeError = removeError
    }

    func workspaceKey(for workspaceID: WorkspaceID) throws -> Data? { nil }
    func storeWorkspaceKey(_ key: Data, for workspaceID: WorkspaceID) throws {}
    func removeWorkspaceKey(for workspaceID: WorkspaceID) throws {
        calls.append("trust.remove")
        lock.withLock { storedRemovedWorkspaceID = workspaceID }
        if let removeError { throw removeError }
    }
}

private final class CaptureSpy: InputCapture, @unchecked Sendable {
    private(set) var suppressed = false
    private(set) var suppressionHistory: [Bool] = []
    var isSuppressionEnabled: Bool { suppressed }
    func start(handler: @escaping @Sendable (InputEvent) -> Bool) throws {}
    func stop() {}
    func setSuppressionEnabled(_ enabled: Bool) {
        suppressed = enabled
        suppressionHistory.append(enabled)
    }
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
    private let frameSendError: Error?
    private let useRealtime: Bool
    private var storedFrames: [InputFrame] = []
    private var storedRealtimeFrames: [RealtimePointerFrame] = []
    private var storedControlMessages: [ControlMessage] = []
    var frames: [InputFrame] { lock.withLock { storedFrames } }
    var realtimeFrames: [RealtimePointerFrame] { lock.withLock { storedRealtimeFrames } }
    var controlMessages: [ControlMessage] { lock.withLock { storedControlMessages } }
    init(frameSendError: Error? = nil, useRealtime: Bool = false) {
        self.frameSendError = frameSendError
        self.useRealtime = useRealtime
    }
    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func events() -> AsyncStream<PeerEvent> { stream }
    func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws {
        lock.withLock { storedControlMessages.append(envelope.message) }
    }
    func send(_ frame: InputFrame, to deviceID: DeviceID) async throws {
        if let frameSendError { throw frameSendError }
        lock.withLock { storedFrames.append(frame) }
    }
    func sendRealtime(_ frame: RealtimePointerFrame, to deviceID: DeviceID) async throws -> Bool {
        if useRealtime {
            lock.withLock { storedRealtimeFrames.append(frame) }
            return true
        }
        try await send(frame.reliableFallback, to: deviceID)
        return false
    }
}
