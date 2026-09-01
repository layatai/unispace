import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class ApplicationTests: XCTestCase {
    func testControlLatencyActivityIsIdempotentAndRecoverable() {
        let activity = ControlLatencyActivity()

        XCTAssertFalse(activity.isActive)
        activity.start()
        activity.start()
        XCTAssertTrue(activity.isActive)
        activity.stop()
        activity.stop()
        XCTAssertFalse(activity.isActive)
    }

    func testControlRoutingKeepsConnectedLegacyAndAcknowledgedPeersAvailable() {
        let legacy = DeviceDescriptor(id: DeviceID(), name: "Legacy")
        let acknowledged = DeviceDescriptor(
            id: DeviceID(),
            name: "Acknowledged",
            capabilities: [.activationAcknowledgementV1]
        )
        let disconnected = DeviceDescriptor(id: DeviceID(), name: "Disconnected")
        let unknownConnectedID = DeviceID()

        let available = ControlRoutingPolicy.availableDeviceIDs(
            connectedDeviceIDs: [legacy.id, acknowledged.id, unknownConnectedID],
            devices: [legacy, acknowledged, disconnected]
        )

        XCTAssertEqual(available, [legacy.id, acknowledged.id])
    }

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

    func testEdgeRouterBypassesOfflineDisplayAndTargetsNextAvailableDevice() throws {
        let localID = DeviceID()
        let offlineID = DeviceID()
        let liveID = DeviceID()
        let localDisplay = display(device: localID, frame: .init(x: 0, y: 0, width: 100, height: 100))
        let offlineDisplay = display(device: offlineID, frame: .init(x: 0, y: 0, width: 100, height: 100))
        let liveDisplay = display(device: liveID, frame: .init(x: 0, y: 0, width: 100, height: 100))
        var topology = DisplayTopology()
        topology.connect(
            .init(displayID: localDisplay.id, edge: .right),
            to: .init(displayID: offlineDisplay.id, edge: .left)
        )
        topology.connect(
            .init(displayID: offlineDisplay.id, edge: .right),
            to: .init(displayID: liveDisplay.id, edge: .left)
        )
        let devices = [
            DeviceDescriptor(id: localID, name: "Local", displays: [localDisplay]),
            DeviceDescriptor(id: offlineID, name: "Offline", displays: [offlineDisplay]),
            DeviceDescriptor(id: liveID, name: "Live", displays: [liveDisplay])
        ]

        let transition = try XCTUnwrap(EdgeRouter.transition(
            x: 100,
            y: 25,
            localDeviceID: localID,
            devices: devices,
            topology: topology,
            availableDeviceIDs: [liveID]
        ))

        XCTAssertEqual(transition.sourceDisplayID, localDisplay.id)
        XCTAssertEqual(transition.sourceEdge, .right)
        XCTAssertEqual(transition.targetDeviceID, liveID)
        XCTAssertEqual(transition.targetDisplayID, liveDisplay.id)
        XCTAssertEqual(transition.entryEdge, .left)
        XCTAssertEqual(transition.normalizedPosition, 0.25)

        let overshotTransition = try XCTUnwrap(EdgeRouter.transition(
            x: 112,
            y: 25,
            localDeviceID: localID,
            devices: devices,
            topology: topology,
            availableDeviceIDs: [liveID]
        ))
        XCTAssertEqual(overshotTransition.targetDeviceID, liveID)
        XCTAssertEqual(overshotTransition.targetDisplayID, liveDisplay.id)

        let returnDestination = try XCTUnwrap(EdgeRouter.reachableDestination(
            from: liveDisplay.id,
            edge: .left,
            devices: devices,
            topology: topology,
            availableDeviceIDs: [localID]
        ))
        XCTAssertEqual(returnDestination.displayID, localDisplay.id)
        XCTAssertEqual(returnDestination.edge, .right)
    }

    func testEdgeRouterDoesNotEnterOfflineChainWithoutAvailableDestination() {
        let localID = DeviceID()
        let offlineID = DeviceID()
        let localDisplay = display(device: localID, frame: .init(x: 0, y: 0, width: 100, height: 100))
        let offlineDisplay = display(device: offlineID, frame: .init(x: 0, y: 0, width: 100, height: 100))
        var topology = DisplayTopology()
        topology.connect(
            .init(displayID: localDisplay.id, edge: .right),
            to: .init(displayID: offlineDisplay.id, edge: .left)
        )

        XCTAssertNil(EdgeRouter.transition(
            x: 100,
            y: 50,
            localDeviceID: localID,
            devices: [
                .init(id: localID, name: "Local", displays: [localDisplay]),
                .init(id: offlineID, name: "Offline", displays: [offlineDisplay])
            ],
            topology: topology,
            availableDeviceIDs: []
        ))
    }

    func testReachableDestinationStopsOnMalformedOfflineCycle() {
        let localID = DeviceID()
        let firstOfflineID = DeviceID()
        let secondOfflineID = DeviceID()
        let localDisplay = display(device: localID, frame: .init(x: 0, y: 0, width: 100, height: 100))
        let firstOfflineDisplay = display(
            device: firstOfflineID,
            frame: .init(x: 0, y: 0, width: 100, height: 100)
        )
        let secondOfflineDisplay = display(
            device: secondOfflineID,
            frame: .init(x: 0, y: 0, width: 100, height: 100)
        )
        let topology = DisplayTopology(links: [
            .init(
                source: .init(displayID: localDisplay.id, edge: .right),
                destination: .init(displayID: firstOfflineDisplay.id, edge: .left)
            ),
            .init(
                source: .init(displayID: firstOfflineDisplay.id, edge: .right),
                destination: .init(displayID: secondOfflineDisplay.id, edge: .left)
            ),
            .init(
                source: .init(displayID: secondOfflineDisplay.id, edge: .right),
                destination: .init(displayID: firstOfflineDisplay.id, edge: .left)
            )
        ])

        XCTAssertNil(EdgeRouter.reachableDestination(
            from: localDisplay.id,
            edge: .right,
            devices: [
                .init(id: localID, name: "Local", displays: [localDisplay]),
                .init(id: firstOfflineID, name: "Offline 1", displays: [firstOfflineDisplay]),
                .init(id: secondOfflineID, name: "Offline 2", displays: [secondOfflineDisplay])
            ],
            topology: topology,
            availableDeviceIDs: []
        ))
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
        let targetDisplay = display(
            device: local,
            frame: .init(x: 0, y: 0, width: 100, height: 100)
        )
        let activation = InputActivation(
            sessionID: SessionID(), epoch: epoch, targetDisplayID: targetDisplay.id, entryEdge: .left, normalizedPosition: 0.5
        )
        await coordinator.receiveActivation(activation, from: remote, targetDisplay: targetDisplay)

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

    func testCoordinatorIgnoresStalePeerDeactivation() async throws {
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
        guard case let .controlling(_, _, sessionID) = await coordinator.currentState() else {
            return XCTFail("Expected an active control session")
        }

        let staleSessionAccepted = await coordinator.receiveDeactivation(sessionID: SessionID(), from: remote)
        let staleSourceAccepted = await coordinator.receiveDeactivation(sessionID: sessionID, from: DeviceID())
        XCTAssertFalse(staleSessionAccepted)
        XCTAssertFalse(staleSourceAccepted)
        XCTAssertTrue(capture.suppressed)

        let matchingAccepted = await coordinator.receiveDeactivation(sessionID: sessionID, from: remote)
        let finalState = await coordinator.currentState()
        let idleAccepted = await coordinator.receiveDeactivation(sessionID: sessionID, from: remote)
        XCTAssertTrue(matchingAccepted)
        XCTAssertEqual(finalState, .idle)
        XCTAssertFalse(idleAccepted)
        XCTAssertFalse(capture.suppressed)
        XCTAssertFalse(transport.controlMessages.contains { message in
            if case .deactivate = message { return true }
            return false
        })
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
        let targetDisplay = display(
            device: local,
            frame: .init(x: 0, y: 0, width: 100, height: 100)
        )
        _ = await coordinator.receiveActivation(
            .init(
                sessionID: sessionID,
                epoch: epoch,
                targetDisplayID: targetDisplay.id,
                entryEdge: .left,
                normalizedPosition: 0.5
            ),
            from: remote,
            targetDisplay: targetDisplay
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
        let targetDisplay = display(
            device: local,
            frame: .init(x: 0, y: 0, width: 100, height: 100)
        )
        let activation = InputActivation(
            sessionID: SessionID(),
            epoch: epoch,
            targetDisplayID: targetDisplay.id,
            entryEdge: .left,
            normalizedPosition: 0.5
        )
        let accepted = await coordinator.receiveActivation(
            activation,
            from: remote,
            targetDisplay: targetDisplay
        )
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

    func testReceiverRejectsActivationUntilInjectionAndDisplayAreReady() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let injector = InjectorSpy()
        let transport = TransportSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: CaptureSpy(),
            injector: injector,
            transport: transport
        )
        let epoch = ControllerEpoch(generation: 1, controllerID: remote)
        await coordinator.observeControllerClaim(epoch)
        let targetDisplay = display(
            device: local,
            frame: .init(x: 0, y: 0, width: 100, height: 100)
        )
        let activation = InputActivation(
            sessionID: SessionID(),
            epoch: epoch,
            targetDisplayID: targetDisplay.id,
            entryEdge: .left,
            normalizedPosition: 0.5
        )

        let unauthorized = await coordinator.receiveActivation(
            activation,
            from: remote,
            targetDisplay: targetDisplay,
            isInputInjectionAuthorized: false
        )
        let missingDisplay = await coordinator.receiveActivation(
            activation,
            from: remote,
            targetDisplay: nil
        )
        let mismatchedDisplay = await coordinator.receiveActivation(
            activation,
            from: remote,
            targetDisplay: display(
                device: local,
                frame: .init(x: 0, y: 0, width: 100, height: 100)
            )
        )
        let accepted = await coordinator.receiveActivation(
            activation,
            from: remote,
            targetDisplay: targetDisplay
        )

        XCTAssertFalse(unauthorized)
        XCTAssertFalse(missingDisplay)
        XCTAssertFalse(mismatchedDisplay)
        XCTAssertTrue(accepted)
        XCTAssertEqual(injector.activationCount, 1)
        XCTAssertEqual(transport.realtimePeerIDs.last ?? nil, remote)
        XCTAssertEqual(transport.realtimeRoles.last, .listener)
        XCTAssertFalse(transport.realtimeRoles.contains(.dialer))
        guard case .receiving = await coordinator.currentState() else {
            return XCTFail("Ready receiver must enter the receiving state")
        }
        await coordinator.stop()
    }

    func testCoordinatorCoalescesPointerMovesWithoutDroppingFinalPosition() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let clock = ManualMonotonicClock()
        let transport = TransportSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: CaptureSpy(),
            injector: InjectorSpy(),
            transport: transport,
            clock: clock
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
        await coordinator.flushPendingInput()

        XCTAssertEqual(transport.frames.count, 1)
        XCTAssertEqual(
            transport.frames.first?.event,
            .pointerMove(deltaX: 4, deltaY: 6, absoluteX: 13, absoluteY: 24)
        )
        await coordinator.stop()
    }

    func testCoordinatorFlushesMotionWhenScheduledFlushMissesItsDeadline() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let clock = ManualMonotonicClock()
        let transport = TransportSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: CaptureSpy(),
            injector: InjectorSpy(),
            transport: transport,
            clock: clock
        )
        _ = await coordinator.makeLocalController()
        try await coordinator.activate(
            target: remote,
            displayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5
        )

        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 1,
            deltaY: 2,
            absoluteX: 10,
            absoluteY: 20
        ))
        XCTAssertTrue(transport.frames.isEmpty)

        clock.advanceWithoutWakingSleepers(
            by: ControlSessionCoordinator.pointerFlushIntervalNanos + 1
        )
        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 3,
            deltaY: 4,
            absoluteX: 13,
            absoluteY: 24
        ))
        await coordinator.flushPendingInput()

        XCTAssertEqual(transport.frames.map(\.event), [
            .pointerMove(deltaX: 4, deltaY: 6, absoluteX: 13, absoluteY: 24)
        ])
        await coordinator.stop()
    }

    func testWindowsPointerMotionKeepsLegacyRealtimeCompatibility() async throws {
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
            normalizedPosition: 0.5,
            targetPlatform: .windows
        )

        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 2,
            deltaY: 1,
            absoluteX: 12,
            absoluteY: 11
        ))
        await coordinator.flushPendingInput()
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
        XCTAssertEqual(transport.realtimePeerIDs.last ?? nil, remote)
        XCTAssertEqual(transport.realtimeRoles.last, .dialer)
        XCTAssertEqual(transport.frames.map(\.event), [
            .mouseButton(button: .left, isDown: true, clickCount: 1),
            .pointerMove(deltaX: 5, deltaY: 0, absoluteX: 17, absoluteY: 11)
        ])
        await coordinator.stop()
    }

    func testMacWithoutProgressCapabilityUsesReliablePointer() async throws {
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
            normalizedPosition: 0.5,
            targetCapabilities: [.udpPointerV2],
            targetPlatform: .macOS
        )

        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 2,
            deltaY: 1,
            absoluteX: 12,
            absoluteY: 11
        ))
        await coordinator.flushPendingInput()

        XCTAssertEqual(transport.frames.map(\.event), [
            .pointerMove(deltaX: 2, deltaY: 1, absoluteX: 12, absoluteY: 11)
        ])
        XCTAssertTrue(transport.realtimeFrames.isEmpty)
        await coordinator.stop()
    }

    func testLegacyRealtimeFailureFallsBackToReliablePointer() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let transport = TransportSpy(
            useRealtime: true,
            realtimeSendError: SpyError.failure
        )
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
            targetPlatform: .windows
        )

        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 2,
            deltaY: 1,
            absoluteX: 12,
            absoluteY: 11
        ))
        await coordinator.flushPendingInput()

        XCTAssertEqual(transport.frames.map(\.event), [
            .pointerMove(deltaX: 2, deltaY: 1, absoluteX: 12, absoluteY: 11)
        ])
        XCTAssertTrue(transport.realtimeReconnects.isEmpty)
        guard case .controlling = await coordinator.currentState() else {
            return XCTFail("Reliable fallback must keep the legacy session active")
        }
        await coordinator.stop()
    }

    func testProgressLaneSendFailuresKeepReliableDeliveryAndReconnect() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let transport = TransportSpy(
            useRealtime: true,
            realtimeSendError: SpyError.failure
        )
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
            targetCapabilities: [.realtimePointerProgressV1],
            targetPlatform: .macOS
        )

        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 1,
            deltaY: 0,
            absoluteX: 11,
            absoluteY: 10
        ))
        await coordinator.flushPendingInput()
        XCTAssertEqual(transport.frames.count, 1)
        XCTAssertTrue(transport.realtimeFrames.isEmpty)

        transport.setRealtimeSendError(nil)
        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 2,
            deltaY: 0,
            absoluteX: 13,
            absoluteY: 10
        ))
        await coordinator.flushPendingInput()
        let probe = try XCTUnwrap(transport.realtimeFrames.last)
        let acknowledged = await coordinator.receiveRealtimePointerProgress(
            .init(
                sessionID: probe.sessionID,
                generation: probe.generation,
                sequence: probe.sequence
            ),
            from: remote
        )
        XCTAssertTrue(acknowledged)

        transport.setRealtimeSendError(SpyError.failure)
        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 3,
            deltaY: 0,
            absoluteX: 16,
            absoluteY: 10
        ))
        await coordinator.flushPendingInput()

        XCTAssertEqual(transport.frames.count, 3)
        XCTAssertEqual(transport.realtimeReconnects, [remote])
        guard case .controlling = await coordinator.currentState() else {
            return XCTFail("Reliable fallback must keep the progress session active")
        }
        await coordinator.stop()
    }

    func testAcknowledgedPointerLaneFallsBackAndReconnectsWhenProgressStops() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let clock = ManualMonotonicClock()
        let transport = TransportSpy(useRealtime: true)
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: CaptureSpy(),
            injector: InjectorSpy(),
            transport: transport,
            clock: clock
        )
        _ = await coordinator.makeLocalController()
        try await coordinator.activate(
            target: remote,
            displayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5,
            targetCapabilities: [.realtimePointerProgressV1],
            targetPlatform: .macOS
        )

        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 2,
            deltaY: 1,
            absoluteX: 12,
            absoluteY: 11
        ))
        await coordinator.flushPendingInput()

        XCTAssertEqual(transport.frames.count, 1, "Probing must keep pointer delivery reliable")
        let probe = try XCTUnwrap(transport.realtimeFrames.last)
        XCTAssertEqual(probe.deltaX, 0)
        XCTAssertEqual(probe.deltaY, 0)
        let acknowledged = await coordinator.receiveRealtimePointerProgress(
            .init(
                sessionID: probe.sessionID,
                generation: probe.generation,
                sequence: probe.sequence
            ),
            from: remote
        )
        XCTAssertTrue(acknowledged)

        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 3,
            deltaY: 0,
            absoluteX: 15,
            absoluteY: 11
        ))
        await coordinator.flushPendingInput()
        XCTAssertEqual(transport.frames.count, 1)
        XCTAssertEqual(transport.realtimeFrames.last?.deltaX, 3)

        clock.advance(by: 500_000_000)
        let repeatedAcknowledgement = await coordinator.receiveRealtimePointerProgress(
            .init(
                sessionID: probe.sessionID,
                generation: probe.generation,
                sequence: probe.sequence
            ),
            from: remote
        )
        XCTAssertFalse(repeatedAcknowledgement, "Stale progress must not refresh lane health")
        clock.advance(by: ControlSessionCoordinator.realtimeProgressTimeoutNanos - 500_000_000 + 1)
        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 4,
            deltaY: 0,
            absoluteX: 19,
            absoluteY: 11
        ))
        await coordinator.flushPendingInput()

        XCTAssertEqual(transport.frames.count, 2)
        XCTAssertEqual(transport.realtimeFrames.last?.deltaX, 0)
        XCTAssertNotEqual(transport.realtimeFrames.last?.generation, probe.generation)
        XCTAssertEqual(transport.realtimeReconnects, [remote])

        let recoveryProbe = try XCTUnwrap(transport.realtimeFrames.last)
        let recovered = await coordinator.receiveRealtimePointerProgress(
            .init(
                sessionID: recoveryProbe.sessionID,
                generation: recoveryProbe.generation,
                sequence: recoveryProbe.sequence
            ),
            from: remote
        )
        XCTAssertTrue(recovered)
        transport.setRealtimeEnabled(false)
        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 5,
            deltaY: 0,
            absoluteX: 24,
            absoluteY: 11
        ))
        await coordinator.flushPendingInput()
        XCTAssertEqual(transport.frames.count, 3)
        XCTAssertEqual(transport.realtimeReconnects, [remote, remote])
        await coordinator.stop()
    }

    func testAcknowledgedPointerFastPathIsSynchronousAndExpiresWithProgress() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let clock = ManualMonotonicClock()
        let transport = TransportSpy(useRealtime: true)
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: CaptureSpy(),
            injector: InjectorSpy(),
            transport: transport,
            clock: clock
        )
        _ = await coordinator.makeLocalController()
        try await coordinator.activate(
            target: remote,
            displayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5,
            targetCapabilities: [.realtimePointerProgressV1],
            targetPlatform: .macOS
        )
        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 1,
            deltaY: 0,
            absoluteX: 10,
            absoluteY: 10
        ))
        await coordinator.flushPendingInput()
        let probe = try XCTUnwrap(transport.realtimeFrames.last)
        let acknowledged = await coordinator.receiveRealtimePointerProgress(
            .init(
                sessionID: probe.sessionID,
                generation: probe.generation,
                sequence: probe.sequence
            ),
            from: remote
        )
        XCTAssertTrue(acknowledged)

        let immediate = InputEvent.pointerMove(
            deltaX: 3,
            deltaY: 2,
            absoluteX: 13,
            absoluteY: 12
        )
        XCTAssertTrue(coordinator.sendCapturedPointerImmediately(immediate))
        XCTAssertEqual(transport.realtimeFrames.last?.deltaX, 3)
        XCTAssertEqual(transport.realtimeFrames.last?.deltaY, 2)

        coordinator.suspendCapturedPointerFastPath()
        XCTAssertFalse(coordinator.sendCapturedPointerImmediately(immediate))
        _ = await coordinator.handleCaptured(.mouseButton(button: .left, isDown: false, clickCount: 1))
        XCTAssertTrue(coordinator.sendCapturedPointerImmediately(immediate))

        clock.advance(by: ControlSessionCoordinator.realtimeProgressTimeoutNanos + 1)
        XCTAssertFalse(coordinator.sendCapturedPointerImmediately(immediate))
        await coordinator.stop()
    }

    func testReceiverReportsLatestAcceptedRealtimeProgress() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let workspaceID = WorkspaceID()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: workspaceID,
            capture: CaptureSpy(),
            injector: InjectorSpy(),
            transport: TransportSpy(),
            election: .init(currentEpoch: .init(generation: 1, controllerID: remote))
        )
        let display = display(device: local, frame: .init(x: 0, y: 0, width: 100, height: 100))
        let sessionID = SessionID()
        let accepted = await coordinator.receiveActivation(
            .init(
                sessionID: sessionID,
                epoch: .init(generation: 1, controllerID: remote),
                targetDisplayID: display.id,
                entryEdge: .left,
                normalizedPosition: 0.5
            ),
            from: remote,
            targetDisplay: display
        )
        XCTAssertTrue(accepted)
        await coordinator.handleIncomingRealtime(.init(
            workspaceID: workspaceID,
            sessionID: sessionID,
            controllerID: remote,
            epoch: .init(generation: 1, controllerID: remote),
            generation: 3,
            sequence: 7,
            deltaX: 0,
            deltaY: 0,
            cumulativeDeltaX: 0,
            cumulativeDeltaY: 0,
            absoluteX: 10,
            absoluteY: 10,
            timestampNanos: 1
        ), from: remote)

        let progress = await coordinator.realtimePointerProgress(sessionID: sessionID, from: remote)
        let invalidProgress = await coordinator.realtimePointerProgress(
            sessionID: sessionID,
            from: DeviceID()
        )
        XCTAssertEqual(progress, .init(sessionID: sessionID, generation: 3, sequence: 7))
        XCTAssertNil(invalidProgress)
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
        await coordinator.flushPendingInput()

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

    func testControllerFailsOpenWhenReliablePointerDeliveryFails() async throws {
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
            normalizedPosition: 0.5,
            targetPlatform: .macOS
        )

        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 4,
            deltaY: 0,
            absoluteX: 10,
            absoluteY: 10
        ))
        await coordinator.flushPendingInput()
        for _ in 0..<100 {
            if await coordinator.currentState() == .idle { break }
            await Task.yield()
        }

        let finalState = await coordinator.currentState()
        XCTAssertEqual(finalState, .idle)
        XCTAssertFalse(capture.suppressed)
        await coordinator.stop()
    }

    func testControllerFailsOpenWhenReliablePointerSendDoesNotComplete() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let clock = ManualMonotonicClock()
        let transport = TransportSpy(frameSendClock: clock)
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: capture,
            injector: InjectorSpy(),
            transport: transport,
            clock: clock
        )
        _ = await coordinator.makeLocalController()
        try await coordinator.activate(
            target: remote,
            displayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5,
            targetPlatform: .macOS
        )
        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 4,
            deltaY: 0,
            absoluteX: 10,
            absoluteY: 10
        ))

        let flush = Task { await coordinator.flushPendingInput() }
        for _ in 0..<100 where clock.pendingSleepCount < 2 { await Task.yield() }
        XCTAssertGreaterThanOrEqual(clock.pendingSleepCount, 2)
        clock.advance(by: ControlSessionCoordinator.realtimeProgressTimeoutNanos)
        await flush.value
        for _ in 0..<100 {
            if await coordinator.currentState() == .idle { break }
            await Task.yield()
        }

        let finalState = await coordinator.currentState()
        XCTAssertEqual(finalState, .idle)
        XCTAssertFalse(capture.suppressed)
        await coordinator.stop()
    }

    func testRealtimeProgressKeepsSessionAliveWhenReliableProbeDeliveryStalls() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let clock = ManualMonotonicClock()
        let transport = TransportSpy(useRealtime: true, frameSendClock: clock)
        let diagnostics = CallRecorder()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: capture,
            injector: InjectorSpy(),
            transport: transport,
            clock: clock,
            diagnostic: diagnostics.append
        )
        _ = await coordinator.makeLocalController()
        try await coordinator.activate(
            target: remote,
            displayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5,
            targetCapabilities: [.realtimePointerProgressV1],
            targetPlatform: .windows
        )

        let delivery = Task {
            _ = await coordinator.handleCaptured(.pointerMove(
                deltaX: 4,
                deltaY: 0,
                absoluteX: 10,
                absoluteY: 10
            ))
            await coordinator.flushPendingInput()
        }
        for _ in 0..<100 where transport.realtimeFrames.isEmpty { await Task.yield() }
        let probe = try XCTUnwrap(transport.realtimeFrames.last)
        let acknowledged = await coordinator.receiveRealtimePointerProgress(
            .init(
                sessionID: probe.sessionID,
                generation: probe.generation,
                sequence: probe.sequence
            ),
            from: remote
        )
        XCTAssertTrue(acknowledged)
        for _ in 0..<100 where clock.pendingSleepCount < 3 { await Task.yield() }
        XCTAssertGreaterThanOrEqual(clock.pendingSleepCount, 3)
        clock.advance(by: ControlSessionCoordinator.realtimeProgressTimeoutNanos)
        await delivery.value

        guard case .controlling = await coordinator.currentState() else {
            return XCTFail("Acknowledged realtime delivery must preserve the active session")
        }
        XCTAssertTrue(capture.suppressed)

        _ = await coordinator.handleCaptured(.pointerMove(
            deltaX: 3,
            deltaY: 1,
            absoluteX: 13,
            absoluteY: 11
        ))
        await coordinator.flushPendingInput()
        XCTAssertEqual(transport.realtimeFrames.last?.deltaX, 3)
        XCTAssertEqual(transport.realtimeFrames.last?.deltaY, 1)
        await coordinator.stop()
        XCTAssertTrue(diagnostics.values.contains { $0.contains("Activating session") })
        XCTAssertTrue(diagnostics.values.contains { $0.contains("Realtime progress established") })
        XCTAssertTrue(diagnostics.values.contains { $0.contains("Reliable pointer timed out") })
        XCTAssertTrue(diagnostics.values.contains { $0.contains("Keeping session") })
        XCTAssertTrue(diagnostics.values.contains { $0.contains("Ending session") })
    }

    func testProgressPeerKeepsSessionWhenReliablePointerStallsButHeartbeatIsFresh() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let clock = ManualMonotonicClock()
        let transport = TransportSpy(useRealtime: true, frameSendClock: clock)
        let diagnostics = CallRecorder()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: capture,
            injector: InjectorSpy(),
            transport: transport,
            clock: clock,
            diagnostic: diagnostics.append
        )
        _ = await coordinator.makeLocalController()
        try await coordinator.activate(
            target: remote,
            displayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5,
            targetCapabilities: [.realtimePointerProgressV1],
            targetPlatform: .windows
        )
        guard case let .controlling(_, _, sessionID) = await coordinator.currentState() else {
            return XCTFail("Expected an active control session")
        }
        let heartbeatLatency = await coordinator.receiveHeartbeatEcho(
            sessionID: sessionID,
            from: remote,
            sentAtNanos: 0
        )
        XCTAssertEqual(heartbeatLatency, 0)

        let delivery = Task {
            _ = await coordinator.handleCaptured(.pointerMove(
                deltaX: 4,
                deltaY: 0,
                absoluteX: 10,
                absoluteY: 10
            ))
            await coordinator.flushPendingInput()
        }
        for _ in 0..<100 where transport.realtimeFrames.isEmpty { await Task.yield() }
        for _ in 0..<100 where clock.pendingSleepCount < 3 { await Task.yield() }
        clock.advance(by: ControlSessionCoordinator.realtimeProgressTimeoutNanos)
        await delivery.value

        guard case .controlling = await coordinator.currentState() else {
            return XCTFail("Fresh control liveness must preserve the session")
        }
        XCTAssertTrue(capture.suppressed)
        XCTAssertEqual(transport.realtimeReconnects, [remote])
        XCTAssertTrue(diagnostics.values.contains { $0.contains("control heartbeat is fresh") })
        await coordinator.stop()
    }

    func testProgressPeerReturnsControlWhenPointerAndHeartbeatAreStale() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let clock = ManualMonotonicClock()
        let transport = TransportSpy(useRealtime: true, frameSendClock: clock)
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: capture,
            injector: InjectorSpy(),
            transport: transport,
            clock: clock
        )
        _ = await coordinator.makeLocalController()
        try await coordinator.activate(
            target: remote,
            displayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5,
            targetCapabilities: [.realtimePointerProgressV1],
            targetPlatform: .windows
        )
        guard case let .controlling(_, _, sessionID) = await coordinator.currentState() else {
            return XCTFail("Expected an active control session")
        }
        _ = await coordinator.receiveHeartbeatEcho(
            sessionID: sessionID,
            from: remote,
            sentAtNanos: 0
        )
        clock.advanceWithoutWakingSleepers(
            by: ControlSessionCoordinator.minimumHeartbeatTimeoutNanos + 1
        )

        let delivery = Task {
            _ = await coordinator.handleCaptured(.pointerMove(
                deltaX: 4,
                deltaY: 0,
                absoluteX: 10,
                absoluteY: 10
            ))
            await coordinator.flushPendingInput()
        }
        for _ in 0..<100 where transport.realtimeFrames.isEmpty { await Task.yield() }
        for _ in 0..<100 where clock.pendingSleepCount < 3 { await Task.yield() }
        clock.advance(by: ControlSessionCoordinator.realtimeProgressTimeoutNanos)
        await delivery.value

        let finalState = await coordinator.currentState()
        XCTAssertEqual(finalState, .idle)
        XCTAssertFalse(capture.suppressed)
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

    func testAcknowledgedActivationStartsOnlyAfterPeerAccepts() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let transport = TransportSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: capture,
            injector: InjectorSpy(),
            transport: transport,
            activationTimeout: .seconds(10)
        )
        _ = await coordinator.makeLocalController()

        let activation = Task {
            try await coordinator.activate(
                target: remote,
                displayID: DisplayID(),
                entryEdge: .left,
                normalizedPosition: 0.5,
                targetCapabilities: [.activationAcknowledgementV1]
            )
        }
        let sessionID = try await activationSessionID(in: transport)

        let wrongSourceAccepted = await coordinator.receiveActivationResult(
            sessionID: sessionID,
            from: DeviceID(),
            accepted: true
        )
        let wrongSessionAccepted = await coordinator.receiveActivationResult(
            sessionID: SessionID(),
            from: remote,
            accepted: true
        )
        let acknowledged = await coordinator.receiveActivationResult(
            sessionID: sessionID,
            from: remote,
            accepted: true
        )
        XCTAssertFalse(wrongSourceAccepted)
        XCTAssertFalse(wrongSessionAccepted)
        XCTAssertTrue(acknowledged)
        try await activation.value

        guard case let .controlling(_, target, session) = await coordinator.currentState() else {
            return XCTFail("Accepted activation must enter the controlling state")
        }
        XCTAssertEqual(target, remote)
        XCTAssertEqual(session, sessionID)
        XCTAssertTrue(capture.suppressed)
        await coordinator.stop()
    }

    func testAcknowledgedActivationBuffersInputUntilPeerAccepts() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let transport = TransportSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: CaptureSpy(),
            injector: InjectorSpy(),
            transport: transport,
            activationTimeout: .seconds(10)
        )
        _ = await coordinator.makeLocalController()

        let pending = AsyncStream<InputEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let activation = Task {
            try await coordinator.activate(
                target: remote,
                displayID: DisplayID(),
                entryEdge: .left,
                normalizedPosition: 0.5,
                targetCapabilities: [.activationAcknowledgementV1],
                initialEvent: .pointerMove(
                    deltaX: 1,
                    deltaY: 0,
                    absoluteX: 100,
                    absoluteY: 50
                ),
                pendingEvents: pending.stream
            )
        }
        let sessionID = try await activationSessionID(in: transport)
        for _ in 0..<500 where !transport.controlMessages.contains(where: {
            guard case let .heartbeat(heartbeatSessionID, _) = $0 else { return false }
            return heartbeatSessionID == sessionID
        }) {
            await Task.yield()
        }
        XCTAssertTrue(transport.controlMessages.contains(where: {
            guard case let .heartbeat(heartbeatSessionID, _) = $0 else { return false }
            return heartbeatSessionID == sessionID
        }), "Acknowledged activation must start heartbeat liveness before confirmation")

        pending.continuation.yield(.key(code: 12, isDown: true, isRepeat: false))
        pending.continuation.finish()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(transport.frames.isEmpty, "Pointer traffic must not delay the activation acknowledgement")

        let acknowledged = await coordinator.receiveActivationResult(
            sessionID: sessionID,
            from: remote,
            accepted: true
        )
        XCTAssertTrue(acknowledged)
        try await activation.value
        for _ in 0..<500 where transport.frames.count < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }
        await coordinator.flushPendingInput()
        XCTAssertEqual(transport.frames.map(\.event), [
            .pointerMove(deltaX: 1, deltaY: 0, absoluteX: 100, absoluteY: 50),
            .key(code: 12, isDown: true, isRepeat: false)
        ])
        await coordinator.stop()
    }

    func testLegacyActivationRequiresHeartbeatConfirmation() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let transport = TransportSpy()
        let clock = ManualMonotonicClock()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: capture,
            injector: InjectorSpy(),
            transport: transport,
            clock: clock,
            activationTimeout: .seconds(10)
        )
        _ = await coordinator.makeLocalController()

        let activation = Task {
            try await coordinator.activate(
                target: remote,
                displayID: DisplayID(),
                entryEdge: .left,
                normalizedPosition: 0.5,
                requiresActivationConfirmation: true
            )
        }
        let sessionID = try await activationSessionID(in: transport)
        var heartbeatTimestamp: UInt64?
        for _ in 0..<500 where heartbeatTimestamp == nil {
            heartbeatTimestamp = transport.controlMessages.compactMap { message -> UInt64? in
                guard case let .heartbeat(heartbeatSessionID, timestamp) = message,
                      heartbeatSessionID == sessionID else { return nil }
                return timestamp
            }.last
            if heartbeatTimestamp == nil { await Task.yield() }
        }
        let sentAt = try XCTUnwrap(heartbeatTimestamp)

        let latency = await coordinator.receiveHeartbeatEcho(
            sessionID: sessionID,
            from: remote,
            sentAtNanos: sentAt
        )
        XCTAssertEqual(latency, 0)
        try await activation.value
        XCTAssertTrue(capture.suppressed)
        guard case .controlling = await coordinator.currentState() else {
            return XCTFail("Heartbeat-confirmed legacy activation must control the peer")
        }
        await coordinator.stop()
    }

    func testRejectedActivationReturnsControlLocally() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let transport = TransportSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: capture,
            injector: InjectorSpy(),
            transport: transport,
            activationTimeout: .seconds(10)
        )
        _ = await coordinator.makeLocalController()

        let activation = Task {
            try await coordinator.activate(
                target: remote,
                displayID: DisplayID(),
                entryEdge: .left,
                normalizedPosition: 0.5,
                targetCapabilities: [.activationAcknowledgementV1]
            )
        }
        let sessionID = try await activationSessionID(in: transport)
        let acknowledged = await coordinator.receiveActivationResult(
            sessionID: sessionID,
            from: remote,
            accepted: false
        )
        XCTAssertTrue(acknowledged)

        do {
            try await activation.value
            XCTFail("Rejected activation must fail")
        } catch {
            XCTAssertEqual(error as? ControlSessionCoordinator.ActivationError, .rejected)
            XCTAssertEqual(error.localizedDescription, "The remote device did not accept control.")
        }
        let state = await coordinator.currentState()
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(capture.suppressed)
    }

    func testActivationTimeoutReturnsControlLocally() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let capture = CaptureSpy()
        let transport = TransportSpy()
        let clock = ManualMonotonicClock()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: capture,
            injector: InjectorSpy(),
            transport: transport,
            clock: clock,
            activationTimeout: .seconds(1)
        )
        _ = await coordinator.makeLocalController()

        let activation = Task {
            try await coordinator.activate(
                target: remote,
                displayID: DisplayID(),
                entryEdge: .left,
                normalizedPosition: 0.5,
                targetCapabilities: [.activationAcknowledgementV1]
            )
        }
        let sessionID = try await activationSessionID(in: transport)
        for _ in 0..<500 where clock.pendingSleepCount == 0 { await Task.yield() }
        XCTAssertGreaterThanOrEqual(clock.pendingSleepCount, 1)
        clock.advance(by: 1_000_000_000)

        do {
            try await activation.value
            XCTFail("Unacknowledged activation must time out")
        } catch {
            XCTAssertEqual(error as? ControlSessionCoordinator.ActivationError, .timedOut)
            XCTAssertEqual(error.localizedDescription, "The remote device did not confirm control in time.")
        }
        let state = await coordinator.currentState()
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(capture.suppressed)
        let lateAcknowledgement = await coordinator.receiveActivationResult(
            sessionID: sessionID,
            from: remote,
            accepted: true
        )
        XCTAssertFalse(lateAcknowledgement)
    }

    func testWindowsActivationAllowsBridgeAcknowledgementLatency() async throws {
        let local = DeviceID()
        let remote = DeviceID()
        let clock = ManualMonotonicClock()
        let transport = TransportSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: local,
            workspaceID: WorkspaceID(),
            capture: CaptureSpy(),
            injector: InjectorSpy(),
            transport: transport,
            clock: clock,
            activationTimeout: .seconds(1)
        )
        _ = await coordinator.makeLocalController()

        let activation = Task {
            try await coordinator.activate(
                target: remote,
                displayID: DisplayID(),
                entryEdge: .left,
                normalizedPosition: 0.5,
                targetCapabilities: [.activationAcknowledgementV1],
                targetPlatform: .windows
            )
        }
        let sessionID = try await activationSessionID(in: transport)
        for _ in 0..<500 where clock.pendingSleepCount == 0 { await Task.yield() }
        clock.advance(by: 2_000_000_000)

        let acknowledged = await coordinator.receiveActivationResult(
            sessionID: sessionID,
            from: remote,
            accepted: true
        )
        XCTAssertTrue(acknowledged)
        try await activation.value
        guard case .controlling = await coordinator.currentState() else {
            return XCTFail("Windows acknowledgement inside the bridge budget must preserve control")
        }
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

private func activationSessionID(in transport: TransportSpy) async throws -> SessionID {
    for _ in 0..<500 {
        if let sessionID = transport.controlMessages.compactMap({ message -> SessionID? in
            guard case let .activate(activation) = message else { return nil }
            return activation.sessionID
        }).last {
            return sessionID
        }
        await Task.yield()
    }
    throw SpyError.failure
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
    private var storedActivationCount = 0
    var events: [InputEvent] { lock.withLock { storedEvents } }
    var releaseAllCount: Int { lock.withLock { storedReleaseCount } }
    var activationCount: Int { lock.withLock { storedActivationCount } }
    func activate(on display: DisplayDescriptor, enteringFrom edge: DisplayEdge, normalizedPosition: Double) {
        lock.withLock { storedActivationCount += 1 }
    }
    func inject(_ event: InputEvent) { lock.withLock { storedEvents.append(event) } }
    func releaseAll() { lock.withLock { storedReleaseCount += 1 } }
}

private final class TransportSpy: PeerTransport, @unchecked Sendable {
    private let stream = AsyncStream<PeerEvent> { $0.finish() }
    private let lock = NSLock()
    private let frameSendError: Error?
    private var realtimeEnabled: Bool
    private var realtimeSendError: Error?
    private let frameSendClock: ManualMonotonicClock?
    private var storedFrames: [InputFrame] = []
    private var storedRealtimeFrames: [RealtimePointerFrame] = []
    private var storedRealtimePeerIDs: [DeviceID?] = []
    private var storedRealtimeRoles: [RealtimeConnectionRole] = []
    private var storedRealtimeReconnects: [DeviceID] = []
    private var storedControlMessages: [ControlMessage] = []
    var frames: [InputFrame] { lock.withLock { storedFrames } }
    var realtimeFrames: [RealtimePointerFrame] { lock.withLock { storedRealtimeFrames } }
    var realtimePeerIDs: [DeviceID?] { lock.withLock { storedRealtimePeerIDs } }
    var realtimeRoles: [RealtimeConnectionRole] { lock.withLock { storedRealtimeRoles } }
    var realtimeReconnects: [DeviceID] { lock.withLock { storedRealtimeReconnects } }
    var controlMessages: [ControlMessage] { lock.withLock { storedControlMessages } }
    init(
        frameSendError: Error? = nil,
        useRealtime: Bool = false,
        realtimeSendError: Error? = nil,
        frameSendClock: ManualMonotonicClock? = nil
    ) {
        self.frameSendError = frameSendError
        self.realtimeEnabled = useRealtime
        self.realtimeSendError = realtimeSendError
        self.frameSendClock = frameSendClock
    }
    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func reconnect(to deviceID: DeviceID) {}
    func reconnectRealtime(to deviceID: DeviceID) {
        lock.withLock { storedRealtimeReconnects.append(deviceID) }
    }
    func setRealtimePeer(_ deviceID: DeviceID?, role: RealtimeConnectionRole) {
        lock.withLock {
            storedRealtimePeerIDs.append(deviceID)
            storedRealtimeRoles.append(role)
        }
    }
    func setRealtimeEnabled(_ enabled: Bool) {
        lock.withLock { realtimeEnabled = enabled }
    }
    func setRealtimeSendError(_ error: Error?) {
        lock.withLock { realtimeSendError = error }
    }
    func events() -> AsyncStream<PeerEvent> { stream }
    func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws {
        lock.withLock { storedControlMessages.append(envelope.message) }
    }
    func send(_ frame: InputFrame, to deviceID: DeviceID) async throws {
        if let frameSendError { throw frameSendError }
        if let frameSendClock { try await frameSendClock.sleep(for: .seconds(60)) }
        lock.withLock { storedFrames.append(frame) }
    }
    func sendRealtime(_ frame: RealtimePointerFrame, to deviceID: DeviceID) async throws -> Bool {
        if let error = lock.withLock({ realtimeSendError }) { throw error }
        if lock.withLock({ realtimeEnabled }) {
            lock.withLock { storedRealtimeFrames.append(frame) }
            return true
        }
        return false
    }
    func sendRealtimeImmediately(_ frame: RealtimePointerFrame, to deviceID: DeviceID) -> Bool {
        lock.withLock {
            guard realtimeEnabled, realtimeSendError == nil else { return false }
            storedRealtimeFrames.append(frame)
            return true
        }
    }
}
