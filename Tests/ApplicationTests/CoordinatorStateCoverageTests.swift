import XCTest
@testable import UniSpaceApplication
import CoreGraphics
import UniSpaceDomain

final class CoordinatorStateCoverageTests: XCTestCase {
    func testEdgeRouterCoversEveryBoundaryAndOvershootDirection() throws {
        let localID = DeviceID()
        let remoteID = DeviceID()
        let localDisplay = display(deviceID: localID)
        let remoteDisplay = display(deviceID: remoteID)
        let devices = [
            DeviceDescriptor(id: localID, name: "Local", displays: [localDisplay]),
            DeviceDescriptor(id: remoteID, name: "Remote", displays: [remoteDisplay])
        ]
        let cases: [(edge: DisplayEdge, boundary: CGPoint, overshoot: CGPoint)] = [
            (.left, .init(x: 0, y: 50), .init(x: -5, y: 50)),
            (.right, .init(x: 100, y: 50), .init(x: 105, y: 50)),
            (.bottom, .init(x: 50, y: 0), .init(x: 50, y: -5)),
            (.top, .init(x: 50, y: 100), .init(x: 50, y: 105))
        ]

        for item in cases {
            var topology = DisplayTopology()
            topology.connect(
                .init(displayID: localDisplay.id, edge: item.edge),
                to: .init(displayID: remoteDisplay.id, edge: item.edge.opposite)
            )
            for point in [item.boundary, item.overshoot] {
                let transition = try XCTUnwrap(EdgeRouter.transition(
                    x: point.x,
                    y: point.y,
                    localDeviceID: localID,
                    devices: devices,
                    topology: topology
                ))
                XCTAssertEqual(transition.sourceEdge, item.edge)
                XCTAssertEqual(transition.entryEdge, item.edge.opposite)
                XCTAssertEqual(transition.targetDeviceID, remoteID)
                XCTAssertEqual(transition.normalizedPosition, 0.5)
            }
        }
    }

    func testEdgeRouterRejectsInteriorUnlinkedMissingAndLocalDestinations() {
        let localID = DeviceID()
        let localDisplay = display(deviceID: localID)
        let otherLocalDisplay = display(deviceID: localID)
        let localDevice = DeviceDescriptor(
            id: localID,
            name: "Local",
            displays: [localDisplay, otherLocalDisplay]
        )

        XCTAssertNil(EdgeRouter.transition(
            x: 50,
            y: 50,
            localDeviceID: localID,
            devices: [localDevice],
            topology: .init()
        ))

        var missingTopology = DisplayTopology()
        missingTopology.connect(
            .init(displayID: localDisplay.id, edge: .left),
            to: .init(displayID: DisplayID(), edge: .right)
        )
        XCTAssertNil(EdgeRouter.transition(
            x: 0,
            y: 50,
            localDeviceID: localID,
            devices: [localDevice],
            topology: missingTopology
        ))

        var localTopology = DisplayTopology()
        localTopology.connect(
            .init(displayID: localDisplay.id, edge: .right),
            to: .init(displayID: otherLocalDisplay.id, edge: .left)
        )
        XCTAssertNil(EdgeRouter.transition(
            x: 100,
            y: 50,
            localDeviceID: localID,
            devices: [localDevice],
            topology: localTopology
        ))
        XCTAssertNil(EdgeRouter.transition(
            x: 150,
            y: 150,
            localDeviceID: localID,
            devices: [localDevice],
            topology: localTopology
        ))
    }

    func testEdgeRouterChoosesNearestOvershotLinkedDisplay() throws {
        let localID = DeviceID()
        let remoteID = DeviceID()
        let nearDisplay = display(deviceID: localID)
        var farDisplay = display(deviceID: localID)
        farDisplay.frame.x = 20
        let remoteDisplay = display(deviceID: remoteID)
        var topology = DisplayTopology()
        topology.connect(
            .init(displayID: nearDisplay.id, edge: .left),
            to: .init(displayID: remoteDisplay.id, edge: .right)
        )
        topology.connect(
            .init(displayID: farDisplay.id, edge: .left),
            to: .init(displayID: remoteDisplay.id, edge: .top)
        )

        let transition = try XCTUnwrap(EdgeRouter.transition(
            x: -5,
            y: 50,
            localDeviceID: localID,
            devices: [
                .init(id: localID, name: "Local", displays: [nearDisplay, farDisplay]),
                .init(id: remoteID, name: "Remote", displays: [remoteDisplay])
            ],
            topology: topology
        ))

        XCTAssertEqual(transition.sourceDisplayID, nearDisplay.id)
    }

    func testConnectionSnapshotPreservesAllDiagnosticFields() {
        let snapshot = ConnectionSnapshot(
            health: .degraded,
            transport: .quic,
            latencyMilliseconds: 275,
            detail: "slow-link"
        )

        XCTAssertEqual(snapshot.health, .degraded)
        XCTAssertEqual(snapshot.transport, .quic)
        XCTAssertEqual(snapshot.latencyMilliseconds, 275)
        XCTAssertEqual(snapshot.detail, "slow-link")
    }

    func testEntryEdgeHysteresisCanResetAndClampsNegativeThreshold() {
        let deviceID = DeviceID()
        let source = display(deviceID: deviceID)
        let transition = EdgeTransition(
            sourceDisplayID: source.id,
            sourceEdge: .left,
            targetDisplayID: DisplayID(),
            targetDeviceID: DeviceID(),
            entryEdge: .right,
            normalizedPosition: 0.5
        )
        var hysteresis = EntryEdgeHysteresis(minimumInwardDistance: -1)

        hysteresis.observe(x: 0, y: 0)
        hysteresis.arm(display: source, entryEdge: .left)
        XCTAssertFalse(hysteresis.allows(transition))
        hysteresis.observe(x: 0, y: 50)
        XCTAssertTrue(hysteresis.allows(transition))
        hysteresis.arm(display: source, entryEdge: .left)
        hysteresis.reset()
        XCTAssertTrue(hysteresis.allows(transition))
    }

    func testPeerTransportDefaultRealtimeLaneReportsUnavailableWithoutSending() async throws {
        let transport = ReliableOnlyTransport()
        let controllerID = DeviceID()
        let targetID = DeviceID()
        let frame = RealtimePointerFrame(
            workspaceID: WorkspaceID(),
            sessionID: SessionID(),
            controllerID: controllerID,
            epoch: .init(generation: 1, controllerID: controllerID),
            generation: 2,
            sequence: 3,
            deltaX: 4,
            deltaY: 5,
            cumulativeDeltaX: 6,
            cumulativeDeltaY: 7,
            absoluteX: 8,
            absoluteY: 9,
            timestampNanos: 10
        )

        let usedRealtime = try await transport.sendRealtime(frame, to: targetID)
        transport.reconnectRealtime(to: targetID)

        XCTAssertFalse(usedRealtime)
        XCTAssertTrue(transport.frames.isEmpty)
        XCTAssertTrue(transport.targets.isEmpty)
    }

    func testHeartbeatLoopAndReceiverWatchdogUseInjectedClock() async throws {
        let controllerID = DeviceID()
        let receiverID = DeviceID()
        let workspaceID = WorkspaceID()
        let controllerClock = ManualMonotonicClock()
        let receiverClock = ManualMonotonicClock()
        let controllerTransport = CoordinatorTransportSpy()
        let receiverInjector = CoordinatorInjectorSpy()
        let controller = ControlSessionCoordinator(
            localDeviceID: controllerID,
            workspaceID: workspaceID,
            capture: CoordinatorCaptureSpy(),
            injector: CoordinatorInjectorSpy(),
            transport: controllerTransport,
            clock: controllerClock
        )
        let receiver = ControlSessionCoordinator(
            localDeviceID: receiverID,
            workspaceID: workspaceID,
            capture: CoordinatorCaptureSpy(),
            injector: receiverInjector,
            transport: CoordinatorTransportSpy(),
            clock: receiverClock
        )
        let epoch = await controller.makeLocalController()
        await receiver.observeControllerClaim(epoch)
        let receiverDisplay = display(deviceID: receiverID)
        try await controller.activate(
            target: receiverID,
            displayID: receiverDisplay.id,
            entryEdge: .left,
            normalizedPosition: 0.5
        )
        guard case let .controlling(_, _, sessionID) = await controller.currentState() else {
            return XCTFail("Expected controller session")
        }
        let heartbeatWaiting = await waitUntil { controllerClock.pendingSleepCount >= 1 }
        XCTAssertTrue(heartbeatWaiting)

        controllerClock.advance(by: 1_000_000_000)
        let heartbeatSent = await waitUntil {
            controllerTransport.controlMessages.contains {
                if case let .heartbeat(id, timestamp) = $0 {
                    return id == sessionID && timestamp == 1_000_000_000
                }
                return false
            }
        }
        XCTAssertTrue(heartbeatSent)

        let activation = InputActivation(
            sessionID: sessionID,
            epoch: epoch,
            targetDisplayID: receiverDisplay.id,
            entryEdge: .right,
            normalizedPosition: 0.5
        )
        let activationAccepted = await receiver.receiveActivation(
            activation,
            from: controllerID,
            targetDisplay: receiverDisplay
        )
        XCTAssertTrue(activationAccepted)
        let wrongHeartbeatAccepted = await receiver.receiveHeartbeat(
            sessionID: SessionID(),
            from: controllerID
        )
        XCTAssertFalse(wrongHeartbeatAccepted)
        receiverClock.advance(by: 1_000_000_000)
        let heartbeatAccepted = await receiver.receiveHeartbeat(sessionID: sessionID, from: controllerID)
        XCTAssertTrue(heartbeatAccepted)
        let watchdogWaiting = await waitUntil { receiverClock.pendingSleepCount >= 1 }
        XCTAssertTrue(watchdogWaiting)
        receiverClock.advance(by: ControlSessionCoordinator.maximumHeartbeatTimeoutNanos + 1)
        let watchdogExpired = await waitUntil {
            await receiver.currentState() == .idle
        }
        XCTAssertTrue(watchdogExpired)
        XCTAssertEqual(receiverInjector.releaseAllCount, 1)

        await controller.stop()
        await receiver.stop()
    }

    func testSlowGestureSendDoesNotStarveHeartbeatStateMachine() async throws {
        let localID = DeviceID()
        let remoteID = DeviceID()
        let clock = ManualMonotonicClock()
        let transport = BlockingInputTransport()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: localID,
            workspaceID: WorkspaceID(),
            capture: CoordinatorCaptureSpy(),
            injector: CoordinatorInjectorSpy(),
            transport: transport,
            clock: clock
        )
        _ = await coordinator.makeLocalController()
        try await coordinator.activate(
            target: remoteID,
            displayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5,
            targetCapabilities: [.publicTrackpadGestures]
        )
        guard case let .controlling(_, _, sessionID) = await coordinator.currentState() else {
            return XCTFail("Expected controller session")
        }
        let heartbeatScheduled = await waitUntil { clock.pendingSleepCount >= 1 }
        XCTAssertTrue(heartbeatScheduled)

        let captureReturned = SendableFlag()
        let captureTask = Task {
            _ = await coordinator.handleCaptured(.gesture(serializedEvent: Data(repeating: 7, count: 512)))
            captureReturned.set()
        }
        let inputSendStarted = await waitUntil { transport.inputSendStarted }
        XCTAssertTrue(inputSendStarted)
        let didCaptureReturn = await waitUntil { captureReturned.value }
        XCTAssertTrue(
            didCaptureReturn,
            "Input backpressure must not block the coordinator actor"
        )

        clock.advance(by: 1_000_000_000)
        let heartbeatSent = await waitUntil {
            transport.controlMessages.contains {
                if case let .heartbeat(id, _) = $0 { return id == sessionID }
                return false
            }
        }
        XCTAssertTrue(
            heartbeatSent,
            "Heartbeat must bypass a slow reliable input send"
        )

        transport.resumeInputSend()
        await captureTask.value
        await coordinator.stop()
    }

    func testSlowReliablePointerDoesNotBlockFollowingCapturedInput() async throws {
        let clock = ManualMonotonicClock()
        let transport = BlockingInputTransport()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: DeviceID(), workspaceID: WorkspaceID(),
            capture: CoordinatorCaptureSpy(), injector: CoordinatorInjectorSpy(),
            transport: transport, clock: clock
        )
        _ = await coordinator.makeLocalController()
        try await coordinator.activate(
            target: DeviceID(), displayID: DisplayID(), entryEdge: .left,
            normalizedPosition: 0.5, targetPlatform: .macOS
        )
        clock.advanceWithoutWakingSleepers(by: ControlSessionCoordinator.pointerFlushIntervalNanos)
        let returned = SendableFlag()
        let captureTask = Task {
            _ = await coordinator.handleCaptured(.pointerMove(deltaX: 4, deltaY: 0, absoluteX: 10, absoluteY: 10))
            returned.set()
        }
        let started = await waitUntil { transport.inputSendStarted }
        XCTAssertTrue(started)
        let didReturn = await waitUntil { returned.value }
        XCTAssertTrue(didReturn, "Pointer backpressure must not hold up the capture event consumer")
        transport.resumeInputSend()
        await captureTask.value
        await coordinator.stop()
    }

    func testStopRemoteControlDoesNotWaitForBlockedInputSend() async throws {
        let localID = DeviceID()
        let remoteID = DeviceID()
        let transport = BlockingInputTransport()
        let capture = CoordinatorCaptureSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: localID,
            workspaceID: WorkspaceID(),
            capture: capture,
            injector: CoordinatorInjectorSpy(),
            transport: transport
        )
        _ = await coordinator.makeLocalController()
        try await coordinator.activate(
            target: remoteID,
            displayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: 0.5,
            targetCapabilities: [.publicTrackpadGestures]
        )
        _ = await coordinator.handleCaptured(.gesture(serializedEvent: Data([1, 2, 3])))
        let inputSendStarted = await waitUntil { transport.inputSendStarted }
        XCTAssertTrue(inputSendStarted)

        let stopReturned = SendableFlag()
        let stopCompleted = expectation(description: "remote control stopped")
        let stopTask = Task {
            await coordinator.deactivateCurrentSession()
            stopReturned.set()
            stopCompleted.fulfill()
        }

        await fulfillment(of: [stopCompleted], timeout: 0.25)
        let didStop = stopReturned.value
        XCTAssertTrue(
            didStop,
            "Stopping remote control must cancel queued input instead of waiting for the network"
        )
        let state = await coordinator.currentState()
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(capture.isSuppressionEnabled)
        XCTAssertTrue(transport.controlMessages.contains {
            if case .deactivate = $0 { return true }
            return false
        })

        transport.resumeInputSend()
        await stopTask.value
        await coordinator.stop()
    }

    func testReceiverStopNotifiesControllerAndReleasesInjectedInput() async throws {
        let localID = DeviceID()
        let controllerID = DeviceID()
        let transport = CoordinatorTransportSpy()
        let injector = CoordinatorInjectorSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: localID,
            workspaceID: WorkspaceID(),
            capture: CoordinatorCaptureSpy(),
            injector: injector,
            transport: transport
        )
        let epoch = ControllerEpoch(generation: 1, controllerID: controllerID)
        let sessionID = SessionID()
        await coordinator.observeControllerClaim(epoch)
        let targetDisplay = display(deviceID: localID)
        let activated = await coordinator.receiveActivation(
            .init(
                sessionID: sessionID,
                epoch: epoch,
                targetDisplayID: targetDisplay.id,
                entryEdge: .left,
                normalizedPosition: 0.5
            ),
            from: controllerID,
            targetDisplay: targetDisplay
        )
        XCTAssertTrue(activated)

        await coordinator.deactivateCurrentSession()

        let finalState = await coordinator.currentState()
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(injector.releaseAllCount, 1)
        XCTAssertTrue(transport.sentControls.contains { sentControl in
            let (target, message) = sentControl
            guard target == controllerID else { return false }
            if case let .deactivate(sentSessionID) = message { return sentSessionID == sessionID }
            return false
        })
    }

    func testHeartbeatValidationAndActivationFailureLeaveCoordinatorIdle() async throws {
        let localID = DeviceID()
        let remoteID = DeviceID()
        let clock = ManualMonotonicClock()
        let transport = CoordinatorTransportSpy()
        let capture = CoordinatorCaptureSpy()
        let coordinator = ControlSessionCoordinator(
            localDeviceID: localID,
            workspaceID: WorkspaceID(),
            capture: capture,
            injector: CoordinatorInjectorSpy(),
            transport: transport,
            clock: clock
        )
        _ = await coordinator.makeLocalController()
        transport.controlError = CoordinatorTestError.expected

        do {
            try await coordinator.activate(
                target: remoteID,
                displayID: DisplayID(),
                entryEdge: .left,
                normalizedPosition: 0.5
            )
            XCTFail("Activation should propagate the transport failure")
        } catch CoordinatorTestError.expected {
            // Expected.
        }
        let state = await coordinator.currentState()
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(capture.isSuppressionEnabled)
        let invalidEcho = await coordinator.receiveHeartbeatEcho(
            sessionID: SessionID(),
            from: remoteID,
            sentAtNanos: 1
        )
        XCTAssertNil(invalidEcho)
        await coordinator.stop()
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

    private func waitUntil(
        attempts: Int = 500,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }
}

private enum CoordinatorTestError: Error {
    case expected
}

final class ManualMonotonicClock: MonotonicClock, @unchecked Sendable {
    private struct Waiter {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var value: UInt64 = 0
    private var waiters: [UUID: Waiter] = [:]

    var pendingSleepCount: Int { lock.withLock { waiters.count } }
    func nowNanoseconds() -> UInt64 { lock.withLock { value } }

    func hasPendingSleep(for duration: Duration) -> Bool {
        lock.withLock {
            let deadline = value &+ Self.nanoseconds(duration)
            return waiters.values.contains { $0.deadline == deadline }
        }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = lock.withLock { () -> Bool in
                    guard !Task.isCancelled else { return true }
                    waiters[id] = Waiter(
                        deadline: value &+ Self.nanoseconds(duration),
                        continuation: continuation
                    )
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.waiters.removeValue(forKey: id)?.continuation }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by nanoseconds: UInt64) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            value &+= nanoseconds
            let ids = waiters.compactMap { $0.value.deadline <= value ? $0.key : nil }
            return ids.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        }
        due.forEach { $0.resume() }
    }

    func advanceWithoutWakingSleepers(by nanoseconds: UInt64) {
        lock.withLock { value &+= nanoseconds }
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(max(components.seconds, 0))
        let fractional = UInt64(max(components.attoseconds / 1_000_000_000, 0))
        return seconds &* 1_000_000_000 &+ fractional
    }
}

private final class ReliableOnlyTransport: PeerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let stream = AsyncStream<PeerEvent> { $0.finish() }
    private var storedFrames: [InputFrame] = []
    private var storedTargets: [DeviceID] = []
    var frames: [InputFrame] { lock.withLock { storedFrames } }
    var targets: [DeviceID] { lock.withLock { storedTargets } }

    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func reconnect(to deviceID: DeviceID) {}
    func events() -> AsyncStream<PeerEvent> { stream }
    func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws {}
    func send(_ frame: InputFrame, to deviceID: DeviceID) async throws {
        lock.withLock {
            storedFrames.append(frame)
            storedTargets.append(deviceID)
        }
    }
}

private final class CoordinatorTransportSpy: PeerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let stream = AsyncStream<PeerEvent> { $0.finish() }
    private var storedControlMessages: [ControlMessage] = []
    private var storedSentControls: [(DeviceID, ControlMessage)] = []
    var controlError: Error?
    var controlMessages: [ControlMessage] { lock.withLock { storedControlMessages } }
    var sentControls: [(DeviceID, ControlMessage)] { lock.withLock { storedSentControls } }

    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func reconnect(to deviceID: DeviceID) {}
    func events() -> AsyncStream<PeerEvent> { stream }
    func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws {
        if let controlError { throw controlError }
        lock.withLock {
            storedControlMessages.append(envelope.message)
            storedSentControls.append((deviceID, envelope.message))
        }
    }
    func send(_ frame: InputFrame, to deviceID: DeviceID) async throws {}
}

private final class BlockingInputTransport: PeerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let stream = AsyncStream<PeerEvent> { $0.finish() }
    private var storedControlMessages: [ControlMessage] = []
    private var inputWaiter: CheckedContinuation<Void, Never>?
    private var storedInputSendStarted = false

    var controlMessages: [ControlMessage] { lock.withLock { storedControlMessages } }
    var inputSendStarted: Bool { lock.withLock { storedInputSendStarted } }

    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func reconnect(to deviceID: DeviceID) {}
    func events() -> AsyncStream<PeerEvent> { stream }

    func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws {
        lock.withLock { storedControlMessages.append(envelope.message) }
    }

    func send(_ frame: InputFrame, to deviceID: DeviceID) async throws {
        await withCheckedContinuation { continuation in
            lock.withLock {
                storedInputSendStarted = true
                inputWaiter = continuation
            }
        }
    }

    func resumeInputSend() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let waiter = inputWaiter
            inputWaiter = nil
            return waiter
        }
        waiter?.resume()
    }
}

private final class SendableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false
    var value: Bool { lock.withLock { storedValue } }
    func set() { lock.withLock { storedValue = true } }
}

private final class CoordinatorCaptureSpy: InputCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var suppressed = false
    var isSuppressionEnabled: Bool { lock.withLock { suppressed } }
    func start(handler: @escaping @Sendable (InputEvent) -> Bool) throws {}
    func stop() {}
    func setSuppressionEnabled(_ enabled: Bool) { lock.withLock { suppressed = enabled } }
}

private final class CoordinatorInjectorSpy: InputInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReleaseAllCount = 0
    var releaseAllCount: Int { lock.withLock { storedReleaseAllCount } }
    func activate(on display: DisplayDescriptor, enteringFrom edge: DisplayEdge, normalizedPosition: Double) {}
    func inject(_ event: InputEvent) {}
    func releaseAll() { lock.withLock { storedReleaseAllCount += 1 } }
}


final class InputRecoveryTests: XCTestCase {
    func testSuccessfulBatchRecoversAfterPreviousSendFailure() async throws {
        let transport = ControlledInputTransport()
        let sender = OrderedInputSender(transport: transport, clock: ManualMonotonicClock())
        let local = DeviceID()
        let target = DeviceID()
        let workspace = WorkspaceID()
        let session = SessionID()
        for sequence: UInt64 in [0, 1] {
            let frame = InputFrame(
                workspaceID: workspace, sessionID: session, controllerID: local,
                epoch: .init(generation: 1, controllerID: local), sequence: sequence,
                timestampNanos: sequence, event: .flags(rawValue: sequence)
            )
            await sender.enqueue(frame, to: target)
            let started = await waitUntil { transport.hasPending(sequence) }
            XCTAssertTrue(started)
            transport.complete(sequence, error: sequence == 0 ? CoordinatorTestError.expected : nil)
            let delivered = await sender.drainOrCancel(after: .milliseconds(750))
            XCTAssertEqual(delivered, sequence == 1)
        }
        await sender.cancelPending()
        transport.completeAll()
    }

    func testSlowLinkCoalescesMotionWithoutCrossingButtonBoundaries() async throws {
        let transport = ControlledInputTransport()
        let sender = OrderedInputSender(transport: transport, clock: ManualMonotonicClock())
        let local = DeviceID()
        let target = DeviceID()
        let workspace = WorkspaceID()
        let session = SessionID()
        func frame(_ sequence: UInt64, _ event: InputEvent) -> InputFrame {
            .init(workspaceID: workspace, sessionID: session, controllerID: local,
                  epoch: .init(generation: 1, controllerID: local), sequence: sequence,
                  timestampNanos: sequence, event: event)
        }
        let down = InputEvent.mouseButton(button: .left, isDown: true, clickCount: 1)
        let up = InputEvent.mouseButton(button: .left, isDown: false, clickCount: 1)
        await sender.enqueue(frame(0, .flags(rawValue: 0)), to: target)
        let started = await waitUntil { transport.hasPending(0) }
        XCTAssertTrue(started)
        for sequence in 1...1_000 {
            await sender.enqueue(frame(UInt64(sequence), .pointerMove(
                deltaX: 1, deltaY: 2, absoluteX: Double(sequence), absoluteY: 9
            )), to: target)
        }
        await sender.enqueue(frame(1_001, down), to: target)
        await sender.enqueue(frame(1_002, .pointerMove(deltaX: 3, deltaY: 4, absoluteX: 1003, absoluteY: 13)), to: target)
        await sender.enqueue(frame(1_003, .pointerMove(deltaX: 5, deltaY: 6, absoluteX: 1008, absoluteY: 19)), to: target)
        await sender.enqueue(frame(1_004, up), to: target)
        for sequence: UInt64 in [0, 1_000, 1_001, 1_003, 1_004] {
            let pending = await waitUntil { transport.hasPending(sequence) }
            XCTAssertTrue(pending, "Missing sequence \(sequence)")
            transport.complete(sequence)
        }
        await sender.cancelPending()
        transport.completeAll()
        XCTAssertEqual(transport.frames.map(\.sequence), [0, 1_000, 1_001, 1_003, 1_004])
        XCTAssertEqual(transport.frames.map(\.event), [
            .flags(rawValue: 0),
            .pointerMove(deltaX: 1000, deltaY: 2000, absoluteX: 1000, absoluteY: 9),
            down, .pointerMove(deltaX: 8, deltaY: 10, absoluteX: 1008, absoluteY: 19), up
        ])
    }

    func testCancelledSendFailureCannotDiscardReplacementQueue() async throws {
        let transport = ControlledInputTransport()
        let sender = OrderedInputSender(transport: transport, clock: ManualMonotonicClock())
        let local = DeviceID()
        let target = DeviceID()
        let workspace = WorkspaceID()
        let session = SessionID()
        func frame(_ sequence: UInt64) -> InputFrame {
            .init(workspaceID: workspace, sessionID: session, controllerID: local,
                  epoch: .init(generation: 1, controllerID: local), sequence: sequence,
                  timestampNanos: sequence, event: .flags(rawValue: sequence))
        }
        await sender.enqueue(frame(0), to: target)
        let firstStarted = await waitUntil { transport.hasPending(0) }
        XCTAssertTrue(firstStarted)
        await sender.cancelPending()
        await sender.enqueue(frame(1), to: target)
        let replacementStarted = await waitUntil { transport.hasPending(1) }
        XCTAssertTrue(replacementStarted)
        await sender.enqueue(frame(2), to: target)
        transport.complete(0, error: CoordinatorTestError.expected)
        for _ in 0..<100 { await Task.yield() }
        transport.complete(1)
        let replacementPreserved = await waitUntil { transport.hasPending(2) }
        XCTAssertTrue(replacementPreserved, "A late error from the cancelled worker must not erase new input")
        transport.complete(2)
        let delivered = await sender.drainOrCancel(after: .milliseconds(750))
        XCTAssertTrue(delivered)
        XCTAssertEqual(transport.frames.map(\.sequence), [0, 1, 2])
        await sender.cancelPending()
        transport.completeAll()
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

private final class ControlledInputTransport: PeerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var storedFrames: [InputFrame] = []
    var frames: [InputFrame] { lock.withLock { storedFrames } }
    func hasPending(_ sequence: UInt64) -> Bool { lock.withLock { waiters[sequence] != nil } }
    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func reconnect(to deviceID: DeviceID) {}
    func events() -> AsyncStream<PeerEvent> { AsyncStream { $0.finish() } }
    func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws {}
    func send(_ frame: InputFrame, to deviceID: DeviceID) async throws {
        // Deliberately ignores cancellation to model a late socket completion.
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                storedFrames.append(frame)
                waiters[frame.sequence] = continuation
            }
        }
    }
    func complete(_ sequence: UInt64, error: Error? = nil) {
        let waiter = lock.withLock { waiters.removeValue(forKey: sequence) }
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
    }
    func completeAll() {
        let pending = lock.withLock {
            let result = Array(waiters.values)
            waiters.removeAll()
            return result
        }
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}
