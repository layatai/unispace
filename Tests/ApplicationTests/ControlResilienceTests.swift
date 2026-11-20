import Foundation
import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class ControlResilienceTests: XCTestCase {
    func testSharedPortableVectorsMatchMacifier() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Documentation/Protocol/control-resilience-v1-vectors.json"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(cases.count, 5)
        for item in cases {
            let control = try XCTUnwrap(item["control"] as? NSDictionary)
            let decoded = try WireFrameCodec.decodePortableControl(JSONSerialization.data(withJSONObject: control))
            let (_, payload) = try WireFrameCodec.decode(WireFrameCodec.encodePortableControl(decoded))
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? NSDictionary)
            XCTAssertEqual(encoded, control)
        }
    }

    func testNewMessagesRoundTripBothWireFormats() throws {
        let session = SessionID()
        let epoch = ControllerEpoch(generation: 8, controllerID: DeviceID())
        let messages: [ControlMessage] = [
            .inputProgress(.init(sessionID: session, sequence: 7)),
            .pointerCheckpoint(.init(sessionID: session, generation: 2, reliableSequence: 7,
                                     cumulativeDeltaX: 12, cumulativeDeltaY: -3)),
            .resume(.init(previousSessionID: session, sessionID: SessionID(), epoch: epoch)),
            .resumeResult(previousSessionID: session, sessionID: SessionID(), accepted: true),
            .resumeResult(previousSessionID: session, sessionID: SessionID(), accepted: false),
        ]
        for message in messages {
            let envelope = ControlEnvelope(message: message)
            let (_, native) = try WireFrameCodec.decode(WireFrameCodec.encodeControl(envelope))
            XCTAssertEqual(try WireFrameCodec.decodeControl(native), envelope)
            let (_, portable) = try WireFrameCodec.decode(WireFrameCodec.encodePortableControl(envelope))
            XCTAssertEqual(try WireFrameCodec.decodePortableControl(portable), envelope)
        }
    }

    func testControllerResumesWithFreshIdentityAndNeverReplaysOutageInput() async throws {
        let fixture = ResilienceFixture()
        let (epoch, original) = try await fixture.control()
        await fixture.coordinator.peerDisconnected(fixture.peer)
        let recovering = await fixture.coordinator.currentState()
        XCTAssertEqual(recovering, .recoveringController(epoch: epoch, target: fixture.peer, session: original))
        XCTAssertTrue(fixture.capture.suppressed)
        let before = fixture.transport.frames.count
        _ = await fixture.coordinator.handleCaptured(.key(code: 12, isDown: true, isRepeat: false))
        XCTAssertEqual(fixture.transport.frames.count, before)
        await fixture.coordinator.peerReconnected(DeviceID())
        XCTAssertFalse(fixture.transport.messages.contains { if case .resume = $0 { true } else { false } })
        await fixture.coordinator.peerReconnected(fixture.peer)
        let request = try XCTUnwrap(fixture.transport.messages.compactMap { message -> ControlSessionResume? in
            if case let .resume(value) = message { value } else { nil }
        }.last)
        XCTAssertEqual(request.previousSessionID, original)
        XCTAssertNotEqual(request.sessionID, original)
        await fixture.coordinator.receiveResumeResult(previous: original, sessionID: request.sessionID,
                                                       accepted: true, from: DeviceID())
        let unchanged = await fixture.coordinator.currentState()
        XCTAssertEqual(unchanged, recovering)
        await fixture.coordinator.receiveResumeResult(previous: original, sessionID: request.sessionID,
                                                       accepted: true, from: fixture.peer)
        let resumed = await fixture.coordinator.currentState()
        XCTAssertEqual(resumed, .controlling(epoch: epoch, target: fixture.peer, session: request.sessionID))
        let stale = await fixture.coordinator.receiveDeactivation(sessionID: original, from: fixture.peer)
        XCTAssertFalse(stale)
        _ = await fixture.coordinator.handleCaptured(.key(code: 12, isDown: false, isRepeat: false))
        await fixture.coordinator.flushPendingInput()
        XCTAssertEqual(fixture.transport.frames.last?.sessionID, request.sessionID)
        XCTAssertEqual(fixture.transport.frames.count, before + 2)
        XCTAssertEqual(fixture.transport.frames[before].event, .flags(rawValue: 0))
        await fixture.coordinator.stop()
    }

    func testRecoveryExpiryAndEmergencyStopReleaseCapture() async throws {
        for emergency in [false, true] {
            let fixture = ResilienceFixture()
            _ = try await fixture.control()
            if emergency {
                _ = await fixture.coordinator.handleCaptured(.flags(rawValue: ControlSessionCoordinator.emergencyFlags))
            }
            await fixture.coordinator.peerDisconnected(fixture.peer)
            if emergency {
                let outcome = await fixture.coordinator.handleCaptured(.key(code: 53, isDown: true, isRepeat: false))
                XCTAssertEqual(outcome, .emergencyStop)
            } else {
                let scheduled = await eventually { fixture.clock.hasPendingSleep(for: .seconds(2)) }
                XCTAssertTrue(scheduled)
                // Repeated disconnects cannot extend ownership indefinitely.
                await fixture.coordinator.peerDisconnected(fixture.peer)
                fixture.clock.advance(by: 2_000_000_000)
                let expired = await eventually { await fixture.coordinator.currentState() == .idle }
                XCTAssertTrue(expired)
            }
            let final = await fixture.coordinator.currentState()
            XCTAssertEqual(final, .idle)
            XCTAssertFalse(fixture.capture.suppressed)
            await fixture.coordinator.stop()
        }
    }

    func testRejectedResumeReleasesBothProposedAndPreviousSession() async throws {
        let fixture = ResilienceFixture()
        let (_, old) = try await fixture.control()
        await fixture.coordinator.peerDisconnected(fixture.peer)
        await fixture.coordinator.peerReconnected(fixture.peer)
        let request = try XCTUnwrap(fixture.transport.messages.compactMap { value -> ControlSessionResume? in
            if case let .resume(request) = value { request } else { nil }
        }.last)
        await fixture.coordinator.receiveResumeResult(previous: old, sessionID: request.sessionID,
                                                       accepted: false, from: fixture.peer)
        let state = await fixture.coordinator.currentState()
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fixture.transport.messages.contains(.deactivate(old)))
        XCTAssertTrue(fixture.transport.messages.contains(.deactivate(request.sessionID)))
        await fixture.coordinator.stop()
    }

    func testReceiverResumeIsIdempotentRejectsOtherPeerAndPreservesCursorPosition() async throws {
        let fixture = ResilienceFixture()
        let (epoch, session) = await fixture.receive()
        await fixture.coordinator.peerDisconnected(fixture.peer)
        let request = ControlSessionResume(previousSessionID: session, sessionID: SessionID(), epoch: epoch)
        await fixture.coordinator.receiveResume(request, from: DeviceID())
        XCTAssertTrue(fixture.transport.messages.contains(.resumeResult(previousSessionID: session, sessionID: request.sessionID, accepted: false)))
        await fixture.coordinator.receiveResume(request, from: fixture.peer)
        await fixture.coordinator.receiveResume(request, from: fixture.peer)
        let state = await fixture.coordinator.currentState()
        XCTAssertEqual(state, .receiving(epoch: epoch, source: fixture.peer, session: request.sessionID))
        XCTAssertEqual(fixture.injector.activationCount, 1, "Resume must preserve the existing cursor position")
        await fixture.coordinator.handleIncoming(fixture.input(session: session, epoch: epoch, sequence: 99), from: fixture.peer)
        XCTAssertTrue(fixture.injector.events.isEmpty, "Old-session input must remain invalid")
        await fixture.coordinator.stop()
    }

    func testCheckpointRecoversLostTailAndFencesDelayedDatagramsAcrossClick() async throws {
        let fixture = ResilienceFixture()
        let (epoch, session) = await fixture.receive()
        let receiver = RealtimeInputReceiver(workspaceID: fixture.workspace, injector: fixture.injector)
        receiver.begin(epoch: epoch, source: fixture.peer, sessionID: session)
        func pointer(_ generation: UInt64, _ sequence: UInt64, _ cumulative: Double) -> RealtimePointerFrame {
            .init(workspaceID: fixture.workspace, sessionID: session, controllerID: fixture.peer, epoch: epoch,
                  generation: generation, sequence: sequence, deltaX: cumulative, deltaY: 0,
                  cumulativeDeltaX: cumulative, cumulativeDeltaY: 0, absoluteX: 0, absoluteY: 0, timestampNanos: 0)
        }
        XCTAssertNotNil(receiver.receive(pointer(1, 0, 3), from: fixture.peer))
        let checkpoint = PointerCheckpoint(sessionID: session, generation: 1, reliableSequence: 10,
                                          cumulativeDeltaX: 8, cumulativeDeltaY: 0)
        XCTAssertTrue(receiver.applyCheckpoint(checkpoint, from: fixture.peer))
        XCTAssertFalse(receiver.applyCheckpoint(checkpoint, from: fixture.peer), "Duplicate checkpoint cannot apply movement twice")
        XCTAssertNil(receiver.receive(pointer(1, 2, 8), from: fixture.peer))
        XCTAssertNil(receiver.receive(pointer(2, 0, 4), from: fixture.peer), "New motion waits for the ordered event")
        receiver.completeReliableInput(sequence: 9)
        XCTAssertNil(receiver.receive(pointer(2, 0, 4), from: fixture.peer))
        receiver.completeReliableInput(sequence: 10)
        XCTAssertNotNil(receiver.receive(pointer(2, 1, 4), from: fixture.peer))
        XCTAssertEqual(fixture.injector.events, [
            .pointerMove(deltaX: 3, deltaY: 0, absoluteX: 0, absoluteY: 0),
            .pointerMove(deltaX: 5, deltaY: 0, absoluteX: 0, absoluteY: 0),
            .pointerMove(deltaX: 4, deltaY: 0, absoluteX: 0, absoluteY: 0),
        ])
        await fixture.coordinator.stop()
    }

    func testApplicationProgressIsEmittedWithoutWaitingForHeartbeat() async throws {
        let fixture = ResilienceFixture()
        let (epoch, session) = await fixture.receive()
        await fixture.coordinator.startIndependentEventHandling()
        let frame = fixture.input(session: session, epoch: epoch, sequence: 4)
        fixture.coordinator.enqueueIndependentEvent(.input(fixture.peer, frame))
        let received = await eventually {
            fixture.transport.messages.contains(.inputProgress(.init(sessionID: session, sequence: 4)))
        }
        XCTAssertTrue(received)
        XCTAssertEqual(fixture.injector.events, [frame.event])
        fixture.coordinator.enqueueIndependentEvent(.input(fixture.peer, frame))
        await Task.yield()
        XCTAssertEqual(fixture.injector.events.count, 1)
        await fixture.coordinator.stop()
    }

    func testReceiverProgressDeadlineFailsOpenEvenWhenSocketAndHeartbeatStayHealthy() async throws {
        let fixture = ResilienceFixture()
        let (_, session) = try await fixture.control()
        _ = await fixture.coordinator.handleCaptured(.key(code: 12, isDown: true, isRepeat: false))
        await fixture.coordinator.flushPendingInput()
        let scheduled = await eventually { fixture.clock.hasPendingSleep(for: .milliseconds(250)) }
        XCTAssertTrue(scheduled)
        fixture.clock.advanceWithoutWakingSleepers(by: ControlSessionCoordinator.inputProgressTimeoutNanos + 1)
        _ = await fixture.coordinator.receiveHeartbeatEcho(sessionID: session, from: fixture.peer,
                                                          sentAtNanos: fixture.clock.nowNanoseconds())
        fixture.clock.advance(by: 1)
        let ended = await eventually { await fixture.coordinator.currentState() == .idle }
        XCTAssertTrue(ended)
        XCTAssertFalse(fixture.capture.suppressed)
        await fixture.coordinator.stop()
    }

    func testInputQueueOverflowIsExplicitAndPreservesExistingBound() async throws {
        let transport = ResilienceTransport()
        transport.blockInput = true
        let sender = OrderedInputSender(transport: transport, clock: ManualMonotonicClock())
        let fixture = ResilienceFixture()
        let epoch = ControllerEpoch(generation: 1, controllerID: fixture.peer)
        let session = SessionID()
        let first = await sender.enqueue(fixture.input(session: session, epoch: epoch, sequence: 0), to: fixture.peer)
        XCTAssertTrue(first)
        let started = await eventually { transport.frames.count == 1 }
        XCTAssertTrue(started)
        for sequence in 1...OrderedInputSender.maximumPendingFrames {
            let accepted = await sender.enqueue(fixture.input(session: session, epoch: epoch, sequence: UInt64(sequence)), to: fixture.peer)
            XCTAssertTrue(accepted)
        }
        let queued = await sender.snapshot()
        XCTAssertEqual(queued.acceptedFrames, UInt64(OrderedInputSender.maximumPendingFrames + 1))
        XCTAssertEqual(queued.pendingFrames, OrderedInputSender.maximumPendingFrames)
        XCTAssertEqual(queued.maximumPendingFrames, OrderedInputSender.maximumPendingFrames)
        XCTAssertEqual(queued.sentFrames, 0)
        XCTAssertEqual(queued.coalescedFrames, 0)
        XCTAssertEqual(queued.oldestPendingAgeNanoseconds, 0)
        let overflow = await sender.enqueue(fixture.input(session: session, epoch: epoch, sequence: 999), to: fixture.peer)
        XCTAssertFalse(overflow)
        let drained = await sender.drainOrCancel(after: .milliseconds(750))
        XCTAssertFalse(drained)
        transport.unblock()
        await sender.cancelPending()
        await fixture.coordinator.stop()
    }

    func testRealtimePromotionWaitsForReliableInjectionAndCheckpointPrecedesButton() async throws {
        let fixture = ResilienceFixture()
        fixture.transport.useRealtime = true
        let (_, session) = try await fixture.control()
        _ = await fixture.coordinator.handleCaptured(.pointerMove(deltaX: 2, deltaY: 0, absoluteX: 2, absoluteY: 0))
        await fixture.coordinator.flushPendingInput()
        let probe = try XCTUnwrap(fixture.transport.pointers.last)
        let accepted = await fixture.coordinator.receiveRealtimePointerProgress(.init(sessionID: session,
            generation: probe.generation, sequence: probe.sequence), from: fixture.peer)
        XCTAssertTrue(accepted)
        let motion = InputEvent.pointerMove(deltaX: 4, deltaY: 0, absoluteX: 6, absoluteY: 0)
        XCTAssertFalse(fixture.coordinator.sendCapturedPointerImmediately(motion), "Unapplied reliable motion is an ordering barrier")
        await fixture.coordinator.receiveInputProgress(.init(sessionID: session, sequence: 999), from: fixture.peer)
        await fixture.coordinator.receiveInputProgress(.init(sessionID: session, sequence: 0), from: DeviceID())
        XCTAssertFalse(fixture.coordinator.sendCapturedPointerImmediately(motion))
        await fixture.coordinator.receiveInputProgress(.init(sessionID: session, sequence: 0), from: fixture.peer)
        XCTAssertTrue(fixture.coordinator.sendCapturedPointerImmediately(motion))
        _ = await fixture.coordinator.handleCaptured(.mouseButton(button: .left, isDown: true, clickCount: 1))
        await fixture.coordinator.flushPendingInput()
        let checkpoint = try XCTUnwrap(fixture.transport.messages.compactMap { message -> PointerCheckpoint? in
            if case let .pointerCheckpoint(value) = message { value } else { nil }
        }.last)
        XCTAssertEqual(checkpoint.cumulativeDeltaX, 4)
        XCTAssertEqual(checkpoint.reliableSequence, 1)
        XCTAssertEqual(Array(fixture.transport.order.suffix(2)), ["checkpoint:1", "input:1"])
        XCTAssertFalse(fixture.coordinator.sendCapturedPointerImmediately(motion))
        _ = await fixture.coordinator.handleCaptured(.pointerMove(deltaX: 1, deltaY: 0, absoluteX: 7, absoluteY: 0))
        _ = await fixture.coordinator.handleCaptured(.mouseButton(button: .left, isDown: false, clickCount: 1))
        await fixture.coordinator.flushPendingInput()
        await fixture.coordinator.receiveInputProgress(.init(sessionID: session, sequence: 3), from: fixture.peer)
        await fixture.coordinator.stop()
    }

    func testLostFinalDatagramIsCheckpointedByHeartbeatAfterCaptureGoesIdle() async throws {
        let fixture = ResilienceFixture()
        fixture.transport.useRealtime = true
        let (_, session) = try await fixture.control()
        _ = await fixture.coordinator.handleCaptured(.pointerMove(deltaX: 1, deltaY: 0, absoluteX: 1, absoluteY: 0))
        await fixture.coordinator.flushPendingInput()
        let probe = try XCTUnwrap(fixture.transport.pointers.last)
        await fixture.coordinator.receiveInputProgress(.init(sessionID: session, sequence: 0), from: fixture.peer)
        _ = await fixture.coordinator.receiveRealtimePointerProgress(.init(sessionID: session,
            generation: probe.generation, sequence: probe.sequence), from: fixture.peer)
        XCTAssertTrue(fixture.coordinator.sendCapturedPointerImmediately(.pointerMove(deltaX: 7, deltaY: -2, absoluteX: 8, absoluteY: 0)))
        let scheduled = await eventually { fixture.clock.hasPendingSleep(for: .milliseconds(250)) }
        XCTAssertTrue(scheduled)
        fixture.clock.advance(by: 1_000_000_000)
        let checkpointed = await eventually {
            fixture.transport.messages.contains {
                if case let .pointerCheckpoint(value) = $0 { value.cumulativeDeltaX == 7 && value.cumulativeDeltaY == -2 } else { false }
            }
        }
        XCTAssertTrue(checkpointed)
        await fixture.coordinator.flushPendingInput()
        XCTAssertEqual(fixture.transport.frames.last?.event, .flags(rawValue: 0))
        await fixture.coordinator.stop()
    }

    func testIndependentReceiverHandlesHeartbeatProgressCheckpointAndResume() async throws {
        let fixture = ResilienceFixture()
        let (epoch, session) = await fixture.receive()
        await fixture.coordinator.startIndependentEventHandling()
        let frame = RealtimePointerFrame(workspaceID: fixture.workspace, sessionID: session, controllerID: fixture.peer,
            epoch: epoch, generation: 1, sequence: 0, deltaX: 2, deltaY: 0, cumulativeDeltaX: 2,
            cumulativeDeltaY: 0, absoluteX: 0, absoluteY: 0, timestampNanos: 0)
        fixture.coordinator.handleIncomingRealtime(frame, from: fixture.peer)
        let progressed = await eventually {
            fixture.transport.messages.contains(.realtimePointerProgress(.init(sessionID: session, generation: 1, sequence: 0)))
        }
        XCTAssertTrue(progressed)
        fixture.coordinator.enqueueIndependentEvent(.control(fixture.peer, ControlEnvelope(message: .heartbeat(sessionID: session, timestampNanos: 12))))
        let processed = await eventually { fixture.clock.hasPendingSleep(for: .milliseconds(16)) }
        XCTAssertTrue(processed)
        fixture.clock.advance(by: 16_000_000)
        let echoed = await eventually {
            fixture.transport.messages.contains(.heartbeat(sessionID: session, timestampNanos: 12))
        }
        XCTAssertTrue(echoed)
        let checkpoint = PointerCheckpoint(sessionID: session, generation: 1, reliableSequence: 0, cumulativeDeltaX: 5, cumulativeDeltaY: 0)
        fixture.coordinator.enqueueIndependentEvent(.control(fixture.peer, ControlEnvelope(message: .pointerCheckpoint(checkpoint))))
        let fenced = await eventually { fixture.injector.events.count == 2 }
        XCTAssertTrue(fenced)
        fixture.coordinator.enqueueIndependentEvent(.input(fixture.peer, fixture.input(session: session, epoch: epoch, sequence: 0)))
        let injected = await eventually { fixture.injector.events.count == 3 }
        XCTAssertTrue(injected)
        await fixture.coordinator.peerDisconnected(fixture.peer)
        let request = ControlSessionResume(previousSessionID: session, sessionID: SessionID(), epoch: epoch)
        fixture.coordinator.enqueueIndependentEvent(.control(fixture.peer, ControlEnvelope(message: .resume(request))))
        let resumed = await eventually { await fixture.coordinator.currentState() == .receiving(epoch: epoch, source: fixture.peer, session: request.sessionID) }
        XCTAssertTrue(resumed)
        await fixture.coordinator.stop()
    }

    func testAdaptivePointerDeadlineIsBoundedAndCannotBeExtendedBySending() {
        let fixture = ResilienceFixture()
        fixture.transport.useRealtime = true
        let sender = RealtimePointerCaptureSender(workspaceID: fixture.workspace, localDeviceID: fixture.local,
                                                  transport: fixture.transport, clock: fixture.clock)
        let session = SessionID()
        sender.enable(epoch: .init(generation: 1, controllerID: fixture.local), target: fixture.peer,
                      sessionID: session, generation: 1, sequence: 1, cumulativePointerX: 0, cumulativePointerY: 0,
                      acknowledgedSequence: 0, acknowledgedAtNanos: 0)
        sender.updateProgressTimeout(roundTripNanos: UInt64.max, jitterNanos: UInt64.max)
        let move = InputEvent.pointerMove(deltaX: 1, deltaY: 1, absoluteX: 0, absoluteY: 0)
        XCTAssertTrue(sender.send(move))
        fixture.clock.advanceWithoutWakingSleepers(by: 1_000_000_000)
        XCTAssertTrue(sender.send(move))
        fixture.clock.advanceWithoutWakingSleepers(by: 2_000_000_001)
        XCTAssertTrue(sender.hasExpiredOutstandingMotion())
        XCTAssertFalse(sender.send(move))
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }
}

private final class ResilienceFixture: @unchecked Sendable {
    let local = DeviceID()
    let peer = DeviceID()
    let workspace = WorkspaceID()
    let clock = ManualMonotonicClock()
    let transport = ResilienceTransport()
    let capture = ResilienceCapture()
    let injector = ResilienceInjector()
    lazy var coordinator = ControlSessionCoordinator(localDeviceID: local, workspaceID: workspace,
        capture: capture, injector: injector, transport: transport, clock: clock)
    let capabilities: Set<DeviceCapability> = [.controlResilienceV1, .realtimePointerProgressV1]

    func control() async throws -> (ControllerEpoch, SessionID) {
        let epoch = await coordinator.makeLocalController()
        try await coordinator.activate(target: peer, displayID: DisplayID(), entryEdge: .left,
                                       normalizedPosition: 0.5, targetCapabilities: capabilities, targetPlatform: .macOS)
        guard case let .controlling(_, _, session) = await coordinator.currentState() else { throw TestFailure.invalidState }
        return (epoch, session)
    }
    func receive() async -> (ControllerEpoch, SessionID) {
        let epoch = ControllerEpoch(generation: 1, controllerID: peer)
        let session = SessionID()
        let display = DisplayDescriptor(id: DisplayID(), deviceID: local, name: "Test",
                                        frame: .init(x: 0, y: 0, width: 100, height: 100), scaleFactor: 1, isMain: true)
        await coordinator.observeControllerClaim(epoch)
        let accepted = await coordinator.receiveActivation(.init(sessionID: session, epoch: epoch,
            targetDisplayID: display.id, entryEdge: .left, normalizedPosition: 0.5), from: peer,
            targetDisplay: display, sourceCapabilities: capabilities)
        XCTAssertTrue(accepted)
        return (epoch, session)
    }
    func input(session: SessionID, epoch: ControllerEpoch, sequence: UInt64) -> InputFrame {
        .init(workspaceID: workspace, sessionID: session, controllerID: peer, epoch: epoch,
              sequence: sequence, timestampNanos: clock.nowNanoseconds(), event: .flags(rawValue: sequence))
    }
    private enum TestFailure: Error { case invalidState }
}

private final class ResilienceCapture: InputCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var suppressed: Bool { lock.withLock { value } }
    var isSuppressionEnabled: Bool { suppressed }
    func start(handler: @escaping @Sendable (InputEvent) -> Bool) throws {}
    func stop() {}
    func setSuppressionEnabled(_ enabled: Bool) { lock.withLock { value = enabled } }
}

private final class ResilienceInjector: InputInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [InputEvent] = []
    private var activations = 0
    var events: [InputEvent] { lock.withLock { storedEvents } }
    var activationCount: Int { lock.withLock { activations } }
    func activate(on display: DisplayDescriptor, enteringFrom edge: DisplayEdge, normalizedPosition: Double) {
        lock.withLock { activations += 1 }
    }
    func inject(_ event: InputEvent) { lock.withLock { storedEvents.append(event) } }
    func releaseAll() {}
}

private final class ResilienceTransport: PeerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var controls: [ControlMessage] = []
    private var inputs: [InputFrame] = []
    private var realtime = false
    private var storedPointers: [RealtimePointerFrame] = []
    private var storedOrder: [String] = []
    var useRealtime: Bool { get { lock.withLock { realtime } } set { lock.withLock { realtime = newValue } } }
    var pointers: [RealtimePointerFrame] { lock.withLock { storedPointers } }
    var order: [String] { lock.withLock { storedOrder } }
    private var blocked = false
    private var waiter: CheckedContinuation<Void, Never>?
    var blockInput: Bool { get { lock.withLock { blocked } } set { lock.withLock { blocked = newValue } } }
    var messages: [ControlMessage] { lock.withLock { controls } }
    var frames: [InputFrame] { lock.withLock { inputs } }
    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func reconnect(to deviceID: DeviceID) {}
    func events() -> AsyncStream<PeerEvent> { AsyncStream { $0.finish() } }
    func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws {
        lock.withLock {
            controls.append(envelope.message)
            if case let .pointerCheckpoint(value) = envelope.message { storedOrder.append("checkpoint:\(value.reliableSequence)") }
        }
    }
    func send(_ frame: InputFrame, to deviceID: DeviceID) async throws {
        await withCheckedContinuation { continuation in
            let shouldBlock = lock.withLock {
                inputs.append(frame)
                storedOrder.append("input:\(frame.sequence)")
                if blocked { waiter = continuation }
                return blocked
            }
            if !shouldBlock { continuation.resume() }
        }
    }
    func sendRealtime(_ frame: RealtimePointerFrame, to deviceID: DeviceID) async throws -> Bool {
        sendRealtimeImmediately(frame, to: deviceID)
    }
    func sendRealtimeImmediately(_ frame: RealtimePointerFrame, to deviceID: DeviceID) -> Bool {
        lock.withLock {
            guard realtime else { return false }
            storedPointers.append(frame)
            return true
        }
    }
    func unblock() {
        let pending = lock.withLock { let pending = waiter; waiter = nil; blocked = false; return pending }
        pending?.resume()
    }
}
