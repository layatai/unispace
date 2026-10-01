import Foundation
import UniSpaceDomain

public actor ControlSessionCoordinator {
    private struct ActiveControlRoute: Sendable {
        let target: DeviceID
        let displayID: DisplayID
        let entryEdge: DisplayEdge
        let normalizedPosition: Double
        let targetCapabilities: Set<DeviceCapability>
    }

    private enum RealtimeDeliveryMode: Sendable, Equatable {
        case legacy
        case reliableOnly
        case probing
        case healthy
        case fallback
    }

    private enum ActivationOutcome: Sendable {
        case accepted
        case rejected
        case timedOut
    }

    private struct PendingActivation {
        let target: DeviceID
        let sessionID: SessionID
        let continuation: AsyncStream<ActivationOutcome>.Continuation
    }

    public enum CapturedInputDisposition: Equatable, Sendable {
        case ignored
        case forwarded
        case emergencyStop
    }

    public enum State: Equatable, Sendable {
        case idle
        case activating(epoch: ControllerEpoch, target: DeviceID, session: SessionID)
        case controlling(epoch: ControllerEpoch, target: DeviceID, session: SessionID)
        case receiving(epoch: ControllerEpoch, source: DeviceID, session: SessionID)
        case recoveringController(epoch: ControllerEpoch, target: DeviceID, session: SessionID)
        case recoveringReceiver(epoch: ControllerEpoch, source: DeviceID, session: SessionID)
    }

    public enum ActivationError: LocalizedError, Equatable, Sendable {
        case rejected
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .rejected:
                "The remote device did not accept control."
            case .timedOut:
                "The remote device did not confirm control in time."
            }
        }
    }

    public static let emergencyKeyCode: UInt16 = 53
    public static let emergencyFlags: UInt64 = 0x0014_0000 | 0x0008_0000 | 0x0004_0000
    public static let heartbeatTimeoutNanos: UInt64 = 10_000_000_000
    public static let minimumHeartbeatTimeoutNanos: UInt64 = 5_000_000_000
    public static let maximumHeartbeatTimeoutNanos: UInt64 = 30_000_000_000
    public static let realtimeProgressTimeoutNanos: UInt64 = 750_000_000
    public static let realtimeProbeIntervalNanos: UInt64 = 250_000_000
    public static let realtimeHeartbeatInterval: Duration = .milliseconds(250)
    public static let reliablePointerTimeout: Duration = .milliseconds(750)
    public static let pointerFlushIntervalNanos: UInt64 = 16_000_000
    public static let windowsActivationTimeout: Duration = .seconds(5)

    private let localDeviceID: DeviceID
    private let workspaceID: WorkspaceID
    private let capture: InputCapture
    private let injector: InputInjector
    private let transport: PeerTransport
    private let inputSender: OrderedInputSender
    private let clock: MonotonicClock
    private let diagnostic: @Sendable (String) -> Void
    private nonisolated let realtimeInputReceiver: RealtimeInputReceiver
    private nonisolated let realtimePointerCaptureSender: RealtimePointerCaptureSender
    private let activationTimeout: Duration
    private let pointerBatchIntervalNanos: UInt64
    private nonisolated let progressReporter: InputProgressReporter
    private let independentEvents: AsyncStream<PeerEvent>
    private nonisolated let independentContinuation: AsyncStream<PeerEvent>.Continuation
    private var independentEventTask: Task<Void, Never>?
    private var receiverCapabilities: Set<DeviceCapability> = []
    private var recoveryTask: Task<Void, Never>?
    private var pendingResume: ControlSessionResume?
    private var lastAcceptedResume: ControlSessionResume?
    private var reliableBarrierSequence: UInt64?
    private var pendingPointerCheckpoint: PointerCheckpoint?
    private var smoothedJitterNanos: UInt64?
    private var pendingLaneProgress: (DeviceID, RealtimePointerProgress)?
    private var lastInputAcknowledgedSequence: UInt64?
    private var inputOutstandingSinceNanos: UInt64?
    private var lastReceivedInputSequence: UInt64?
    public static let sessionRecoveryTimeout: Duration = .seconds(2)
    public static let inputProgressTimeoutNanos: UInt64 = 5_000_000_000
    private let sessionStream: AsyncStream<ControlSessionSnapshot>
    private let sessionContinuation: AsyncStream<ControlSessionSnapshot>.Continuation
    private var election: ControllerStateMachine
    private var remoteInputState = RemoteInputState()
    private var currentFlags: UInt64 = 0
    private var sequence: UInt64 = 0
    private var realtimeGeneration: UInt64 = 0
    private var realtimeSequence: UInt64 = 0
    private var cumulativePointerX: Double = 0
    private var cumulativePointerY: Double = 0
    private var realtimeDeliveryMode: RealtimeDeliveryMode = .legacy
    private var lastRealtimeSentSequence: UInt64?
    private var lastRealtimeProbeNanos: UInt64?
    private var pressedButtons: Set<PointerButton> = []
    private var state: State = .idle
    private var pendingPointerEvent: InputEvent?
    private var pendingScrollEvent: InputEvent?
    private var pointerFlushTask: Task<Void, Never>?
    private var reliablePointerTask: Task<Void, Never>?
    private var reliablePointerRevision: UInt64 = 0
    private var lastMotionFlushNanos: UInt64?
    private var heartbeatTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastHeartbeatNanos: UInt64 = 0
    private var lastHeartbeatEchoNanos: UInt64?
    private var smoothedHeartbeatIntervalNanos: UInt64?
    private var smoothedRoundTripNanos: UInt64?
    private var activeControlRoute: ActiveControlRoute?
    private var pendingActivation: PendingActivation?
    private var activationTimeoutTask: Task<Void, Never>?
    private var activationInputTask: Task<Void, Never>?
    private var lastSessionSnapshot = ControlSessionSnapshot.idle

    public init(
        localDeviceID: DeviceID,
        workspaceID: WorkspaceID,
        capture: InputCapture,
        injector: InputInjector,
        transport: PeerTransport,
        clock: MonotonicClock = SystemMonotonicClock(),
        activationTimeout: Duration = .seconds(2),
        pointerBatchIntervalNanos: UInt64 = ControlSessionCoordinator.pointerFlushIntervalNanos,
        election: ControllerStateMachine = .init(),
        diagnostic: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        precondition(activationTimeout > .zero)
        self.localDeviceID = localDeviceID
        self.workspaceID = workspaceID
        self.capture = capture
        self.injector = injector
        self.transport = transport
        self.inputSender = OrderedInputSender(transport: transport, clock: clock)
        self.clock = clock
        self.diagnostic = diagnostic
        self.realtimeInputReceiver = RealtimeInputReceiver(
            workspaceID: workspaceID,
            injector: injector
        )
        self.realtimePointerCaptureSender = RealtimePointerCaptureSender(
            workspaceID: workspaceID,
            localDeviceID: localDeviceID,
            transport: transport,
            clock: clock
        )
        self.activationTimeout = activationTimeout
        self.pointerBatchIntervalNanos = pointerBatchIntervalNanos
        progressReporter = InputProgressReporter(transport: transport, clock: clock)
        let events = AsyncStream<PeerEvent>.makeStream()
        independentEvents = events.stream
        independentContinuation = events.continuation
        self.election = election
        let pair = AsyncStream<ControlSessionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        sessionStream = pair.stream
        sessionContinuation = pair.continuation
        sessionContinuation.yield(.idle)
    }

    deinit { sessionContinuation.finish() }

    public func currentState() -> State { state }
    public func inputQueueSnapshot() async -> InputQueueSnapshot { await inputSender.snapshot() }
    public func sessionSnapshots() -> AsyncStream<ControlSessionSnapshot> { sessionStream }

    @discardableResult
    public func makeLocalController() async -> ControllerEpoch {
        let epoch = election.claim(for: localDeviceID)
        await endCurrentSession(notifyPeer: true, reason: "local controller claimed")
        setState(.idle)
        return epoch
    }

    public func observeControllerClaim(_ epoch: ControllerEpoch) async {
        guard election.observe(epoch) else { return }
        if epoch.controllerID != localDeviceID {
            await endCurrentSession(notifyPeer: false, reason: "remote controller claimed")
        }
    }

    public func activate(
        target: DeviceID,
        displayID: DisplayID,
        entryEdge: DisplayEdge,
        normalizedPosition: Double,
        targetCapabilities: Set<DeviceCapability> = [],
        targetPlatform: DevicePlatform = .unknown,
        requiresActivationConfirmation: Bool = false,
        initialEvent: InputEvent? = nil,
        pendingEvents: AsyncStream<InputEvent>? = nil
    ) async throws {
        guard let epoch = election.currentEpoch, epoch.controllerID == localDeviceID else { return }
        if case .idle = state {
            // Input capture may already be synchronously pre-armed by the edge event tap.
        } else {
            await endCurrentSession(notifyPeer: true, reason: "session replaced")
        }
        let sessionID = SessionID()
        diagnostic("Activating session \(sessionID) for peer \(target); platform=\(targetPlatform.rawValue)")
        resetRealtimeSender(incrementGeneration: true)
        setState(.activating(epoch: epoch, target: target, session: sessionID))
        activeControlRoute = ActiveControlRoute(
            target: target,
            displayID: displayID,
            entryEdge: entryEdge,
            normalizedPosition: normalizedPosition,
            targetCapabilities: targetCapabilities
        )
        realtimeDeliveryMode = if targetCapabilities.contains(.realtimePointerProgressV1) {
            .probing
        } else if targetPlatform == .macOS {
            .reliableOnly
        } else {
            .legacy
        }
        capture.setSuppressionEnabled(true)
        transport.setRealtimePeer(target, role: .dialer)
        let supportsExplicitAcknowledgement = targetCapabilities.contains(.activationAcknowledgementV1)
        let confirmationTimeout = targetPlatform.isPortableReceiver
            ? max(activationTimeout, Self.windowsActivationTimeout)
            : activationTimeout
        let activationResults = (requiresActivationConfirmation || supportsExplicitAcknowledgement)
            ? beginActivationWait(target: target, sessionID: sessionID, timeout: confirmationTimeout)
            : nil
        do {
            try await transport.send(
                ControlEnvelope(message: .activate(.init(
                    sessionID: sessionID,
                    epoch: epoch,
                    targetDisplayID: displayID,
                    entryEdge: entryEdge,
                    normalizedPosition: normalizedPosition
                ))),
                to: target
            )
            setState(.controlling(epoch: epoch, target: target, session: sessionID))
            diagnostic("Session \(sessionID) is controlling peer \(target); mode=\(realtimeDeliveryMode)")
            lastMotionFlushNanos = clock.nowNanoseconds()
            if let activationResults {
                await sendHeartbeat(target: target, sessionID: sessionID)
                startHeartbeat(target: target, sessionID: sessionID)
                switch await firstActivationOutcome(from: activationResults) {
                case .accepted:
                    break
                case .rejected:
                    throw ActivationError.rejected
                case .timedOut:
                    throw ActivationError.timedOut
                }
            } else {
                startHeartbeat(target: target, sessionID: sessionID)
            }
            if let initialEvent {
                _ = await handleCaptured(initialEvent)
            }
            if let pendingEvents {
                activationInputTask?.cancel()
                activationInputTask = Task(priority: realtimeInputTaskPriority) { [weak self] in
                    for await event in pendingEvents {
                        guard !Task.isCancelled, let self else { return }
                        _ = await self.handleCaptured(event)
                    }
                }
            }
            if realtimeDeliveryMode == .legacy {
                realtimePointerCaptureSender.enable(
                    epoch: epoch,
                    target: target,
                    sessionID: sessionID,
                    generation: realtimeGeneration,
                    sequence: realtimeSequence,
                    cumulativePointerX: cumulativePointerX,
                    cumulativePointerY: cumulativePointerY
                )
            }
        } catch {
            diagnostic("Activation failed for session \(sessionID): \(error.localizedDescription)")
            await endCurrentSession(notifyPeer: false, reason: "activation failed")
            throw error
        }
    }

    @discardableResult
    public func receiveActivationResult(
        sessionID: SessionID,
        from source: DeviceID,
        accepted: Bool
    ) -> Bool {
        let handled = finishPendingActivation(
            target: source,
            sessionID: sessionID,
            outcome: accepted ? .accepted : .rejected
        )
        diagnostic("t=\(clock.nowNanoseconds()) activation result for session \(sessionID); accepted=\(accepted), handled=\(handled)")
        return handled
    }

    public func receiveActivation(
        _ activation: InputActivation,
        from source: DeviceID,
        targetDisplay: DisplayDescriptor?,
        isInputInjectionAuthorized: Bool = true,
        sourceCapabilities: Set<DeviceCapability> = []
    ) async -> Bool {
        let epoch = activation.epoch
        guard election.currentEpoch == epoch,
              epoch.controllerID == source,
              isInputInjectionAuthorized,
              let targetDisplay,
              targetDisplay.id == activation.targetDisplayID,
              targetDisplay.deviceID == localDeviceID else { return false }
        await endCurrentSession(notifyPeer: false, reason: "incoming activation")
        injector.activate(
            on: targetDisplay,
            enteringFrom: activation.entryEdge,
            normalizedPosition: activation.normalizedPosition
        )
        receiverCapabilities = sourceCapabilities
        progressReporter.start()
        realtimeInputReceiver.begin(
            epoch: epoch,
            source: source,
            sessionID: activation.sessionID
        )
        setState(.receiving(epoch: epoch, source: source, session: activation.sessionID))
        transport.setRealtimePeer(source, role: .listener)
        lastHeartbeatNanos = clock.nowNanoseconds()
        startWatchdog(source: source, sessionID: activation.sessionID)
        return true
    }

    public func handleCaptured(_ event: InputEvent) async -> CapturedInputDisposition {
        if Self.isEmergencyStop(event, flags: currentFlags) {
            await endCurrentSession(notifyPeer: true, reason: "emergency stop")
            return .emergencyStop
        }
        if case .recoveringController = state {
            // Outage input is never replayed into a resumed session.
            if case let .flags(rawValue) = event { currentFlags = rawValue }
            return .forwarded
        }
        guard case .controlling = state else { return .ignored }
        if case .gesture = event {
            let capabilities = activeControlRoute?.targetCapabilities ?? []
            guard capabilities.contains(.publicTrackpadGestures)
                    || capabilities.contains(.portableTrackpadGestures) else {
                return .forwarded
            }
        }
        if case let .flags(rawValue) = event {
            currentFlags = rawValue
        }
        if Self.isEmergencyStop(event, flags: currentFlags) {
            await endCurrentSession(notifyPeer: true, reason: "emergency stop")
            return .emergencyStop
        }
        if case let .mouseButton(button, isDown, _) = event {
            if isDown { realtimePointerCaptureSender.suspend() }
            await flushPendingMotion()
            if isDown { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
            await sendInput(event)
            if pressedButtons.isEmpty { realtimePointerCaptureSender.resume() }
            return .forwarded
        }
        if case let .pointerMove(deltaX, deltaY, absoluteX, absoluteY) = event {
            guard pressedButtons.isEmpty else {
                await flushPendingMotion()
                await sendInput(event)
                return .forwarded
            }
            if case let .pointerMove(pendingX, pendingY, _, _) = pendingPointerEvent {
                pendingPointerEvent = .pointerMove(
                    deltaX: pendingX + deltaX,
                    deltaY: pendingY + deltaY,
                    absoluteX: absoluteX,
                    absoluteY: absoluteY
                )
            } else {
                pendingPointerEvent = event
            }
            await flushPendingMotionIfDue()
            return .forwarded
        }
        if case let .scroll(deltaX, deltaY, isContinuous) = event {
            if case let .scroll(pendingX, pendingY, pendingContinuous) = pendingScrollEvent,
               pendingContinuous == isContinuous {
                pendingScrollEvent = .scroll(
                    deltaX: pendingX + deltaX,
                    deltaY: pendingY + deltaY,
                    isContinuous: isContinuous
                )
            } else {
                await flushPendingMotion()
                pendingScrollEvent = event
            }
            await flushPendingMotionIfDue()
            return .forwarded
        }
        await flushPendingMotion()
        await sendInput(event)
        return .forwarded
    }

    @discardableResult
    public func receiveHeartbeat(sessionID: SessionID, from source: DeviceID) -> Bool {
        guard case let .receiving(_, expectedSource, expectedSession) = state,
              source == expectedSource, sessionID == expectedSession else { return false }
        let now = clock.nowNanoseconds()
        if lastHeartbeatNanos > 0, now > lastHeartbeatNanos {
            smoothedHeartbeatIntervalNanos = Self.smoothed(
                previous: smoothedHeartbeatIntervalNanos,
                sample: now - lastHeartbeatNanos
            )
        }
        lastHeartbeatNanos = now
        return true
    }

    public func receiveHeartbeatEcho(
        sessionID: SessionID,
        from source: DeviceID,
        sentAtNanos: UInt64
    ) -> Int? {
        guard case let .controlling(_, target, expectedSession) = state,
              source == target, sessionID == expectedSession else { return nil }
        let now = clock.nowNanoseconds()
        guard now >= sentAtNanos else { return nil }
        _ = finishPendingActivation(
            target: source,
            sessionID: sessionID,
            outcome: .accepted
        )
        let sample = now - sentAtNanos
        let previous = smoothedRoundTripNanos ?? sample
        smoothedJitterNanos = Self.smoothed(previous: smoothedJitterNanos,
                                           sample: sample >= previous ? sample - previous : previous - sample)
        smoothedRoundTripNanos = Self.smoothed(previous: smoothedRoundTripNanos, sample: sample)
        realtimePointerCaptureSender.updateProgressTimeout(roundTripNanos: smoothedRoundTripNanos ?? sample,
                                                          jitterNanos: smoothedJitterNanos ?? 0)
        lastHeartbeatEchoNanos = now
        publishSessionSnapshotIfChanged()
        diagnostic("t=\(now) heartbeat echo for session \(sessionID); latency=\(Int((smoothedRoundTripNanos ?? 0) / 1_000_000))ms")
        return Int((smoothedRoundTripNanos ?? 0) / 1_000_000)
    }

    private func sendInput(_ event: InputEvent) async {
        guard case let .controlling(epoch, target, sessionID) = state else { return }
        let frame = InputFrame(
            workspaceID: workspaceID,
            sessionID: sessionID,
            controllerID: localDeviceID,
            epoch: epoch,
            sequence: sequence,
            timestampNanos: clock.nowNanoseconds(),
            event: event
        )
        sequence &+= 1
        var checkpoint: PointerCheckpoint?
        if supportsResilience {
            checkpoint = pendingPointerCheckpoint ?? realtimePointerCaptureSender.takeCheckpoint(reliableSequence: frame.sequence)
            pendingPointerCheckpoint = nil
            if let checkpoint {
                realtimeGeneration = checkpoint.generation &+ 1
                realtimeSequence = 0
                cumulativePointerX = 0
                cumulativePointerY = 0
                lastRealtimeSentSequence = nil
                lastRealtimeProbeNanos = nil
                realtimeDeliveryMode = .probing
                reliableBarrierSequence = frame.sequence
            }
            if inputOutstandingSinceNanos == nil { inputOutstandingSinceNanos = clock.nowNanoseconds() }
        }
        let accepted = await inputSender.enqueue(frame, to: target, checkpoint: checkpoint)
        if !accepted {
            diagnostic("Reliable input queue exceeded its bound; releasing session \(sessionID)")
            await endCurrentSession(notifyPeer: true, reason: "input queue overflow")
        }
    }

    public func handleIncoming(_ frame: InputFrame, from source: DeviceID) async {
        guard election.accepts(frame), frame.controllerID == source else { return }
        guard case let .receiving(epoch, expectedSource, sessionID) = state,
              epoch == frame.epoch,
              expectedSource == source,
              sessionID == frame.sessionID else { return }
        guard frame.workspaceID == workspaceID,
              lastReceivedInputSequence.map({ frame.sequence > $0 }) ?? true else { return }
        lastReceivedInputSequence = frame.sequence
        remoteInputState.apply(frame.event)
        injector.inject(frame.event)
        realtimeInputReceiver.completeReliableInput(sequence: frame.sequence)
        lastHeartbeatNanos = clock.nowNanoseconds()
        if receiverCapabilities.contains(.controlResilienceV1) {
            progressReporter.record(.init(sessionID: frame.sessionID, sequence: frame.sequence), from: source)
        }
    }

    public nonisolated func handleIncomingRealtime(
        _ frame: RealtimePointerFrame,
        from source: DeviceID
    ) {
        if let progress = realtimeInputReceiver.receive(frame, from: source) {
            // The receiver only enables direct progress for negotiated sessions.
            independentContinuation.yield(.control(source, ControlEnvelope(message: .realtimePointerProgress(progress))))
        }
    }

    public nonisolated func sendCapturedPointerImmediately(_ event: InputEvent) -> Bool {
        realtimePointerCaptureSender.send(event)
    }

    public nonisolated func suspendCapturedPointerFastPath() {
        realtimePointerCaptureSender.suspend()
    }

    public func realtimePointerProgress(
        sessionID: SessionID,
        from source: DeviceID
    ) -> RealtimePointerProgress? {
        guard case let .receiving(_, expectedSource, expectedSession) = state,
              source == expectedSource, sessionID == expectedSession else { return nil }
        return realtimeInputReceiver.progress(sessionID: sessionID, source: source)
    }

    @discardableResult
    public func receiveRealtimePointerProgress(
        _ progress: RealtimePointerProgress,
        from source: DeviceID
    ) -> Bool {
        if realtimePointerCaptureSender.acknowledge(progress, from: source) {
            diagnostic("Realtime progress accepted for session \(progress.sessionID); generation=\(progress.generation), sequence=\(progress.sequence)")
            return true
        }
        guard realtimeDeliveryMode != .healthy else {
            diagnostic("Realtime progress ignored for healthy session \(progress.sessionID); generation=\(progress.generation), sequence=\(progress.sequence)")
            return false
        }
        guard case let .controlling(epoch, target, sessionID) = state,
              source == target, progress.sessionID == sessionID,
              progress.generation == realtimeGeneration,
              let lastRealtimeSentSequence,
              progress.sequence <= lastRealtimeSentSequence else {
            diagnostic("Realtime progress rejected for session \(progress.sessionID); generation=\(progress.generation), sequence=\(progress.sequence), expectedGeneration=\(realtimeGeneration)")
            return false
        }
        if supportsResilience, inputOutstandingSinceNanos != nil {
            pendingLaneProgress = (source, progress)
            return true
        }
        let acknowledgedAtNanos = clock.nowNanoseconds()
        realtimeDeliveryMode = .healthy
        diagnostic("Realtime progress established for session \(progress.sessionID); generation=\(progress.generation), sequence=\(progress.sequence)")
        realtimePointerCaptureSender.enable(
            epoch: epoch,
            target: source,
            sessionID: progress.sessionID,
            generation: realtimeGeneration,
            sequence: realtimeSequence,
            cumulativePointerX: cumulativePointerX,
            cumulativePointerY: cumulativePointerY,
            acknowledgedSequence: progress.sequence,
            acknowledgedAtNanos: acknowledgedAtNanos
        )
        return true
    }

    public func startIndependentEventHandling() {
        guard independentEventTask == nil else { return }
        let events = independentEvents
        independentEventTask = Task(priority: realtimeInputTaskPriority) { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                await self.handleIndependentEvent(event)
            }
        }
    }

    public nonisolated func enqueueIndependentEvent(_ event: PeerEvent) {
        independentContinuation.yield(event)
    }

    private var supportsResilience: Bool {
        activeControlRoute?.targetCapabilities.contains(.controlResilienceV1) == true
    }

    private func handleIndependentEvent(_ event: PeerEvent) async {
        switch event {
        case let .input(source, frame):
            await handleIncoming(frame, from: source)
        case let .control(source, envelope):
            switch envelope.message {
            case let .heartbeat(sessionID, timestamp):
                if receiveHeartbeat(sessionID: sessionID, from: source) {
                    if let progress = realtimePointerProgress(sessionID: sessionID, from: source) {
                        progressReporter.record(progress, from: source)
                    }
                    progressReporter.recordHeartbeat(envelope, from: source)
                } else {
                    _ = receiveHeartbeatEcho(sessionID: sessionID, from: source, sentAtNanos: timestamp)
                }
            case let .realtimePointerProgress(progress):
                if case let .receiving(_, peer, sessionID) = state, peer == source,
                   sessionID == progress.sessionID, receiverCapabilities.contains(.controlResilienceV1) {
                    progressReporter.record(progress, from: source)
                } else {
                    _ = receiveRealtimePointerProgress(progress, from: source)
                }
            case let .inputProgress(progress):
                receiveInputProgress(progress, from: source)
            case let .pointerCheckpoint(checkpoint):
                if receiverCapabilities.contains(.controlResilienceV1),
                   case let .receiving(_, peer, sessionID) = state,
                   peer == source, sessionID == checkpoint.sessionID {
                    _ = realtimeInputReceiver.applyCheckpoint(checkpoint, from: source)
                }
            case let .resume(request):
                await receiveResume(request, from: source)
            case let .resumeResult(previous, sessionID, accepted):
                await receiveResumeResult(previous: previous, sessionID: sessionID, accepted: accepted, from: source)
            default:
                break
            }
        default:
            break
        }
    }

    public func receiveInputProgress(_ progress: InputDeliveryProgress, from source: DeviceID) {
        guard supportsResilience, case let .controlling(_, peer, sessionID) = state,
              peer == source, sessionID == progress.sessionID, progress.sequence < sequence,
              lastInputAcknowledgedSequence.map({ progress.sequence > $0 }) ?? true else { return }
        lastInputAcknowledgedSequence = progress.sequence
        inputOutstandingSinceNanos = progress.sequence &+ 1 == sequence ? nil : clock.nowNanoseconds()
        if let barrier = reliableBarrierSequence, progress.sequence >= barrier {
            reliableBarrierSequence = nil
        }
        if inputOutstandingSinceNanos == nil, let (peer, progress) = pendingLaneProgress {
            pendingLaneProgress = nil
            _ = receiveRealtimePointerProgress(progress, from: peer)
        }
        diagnostic("Input injected through sequence \(progress.sequence) for session \(sessionID)")
    }

    public func peerDisconnected(_ deviceID: DeviceID) async {
        switch state {
        case let .controlling(epoch, target, sessionID) where target == deviceID && supportsResilience:
            await beginRecovery(.recoveringController(epoch: epoch, target: target, session: sessionID))
            transport.reconnect(to: target)
        case let .receiving(epoch, source, sessionID) where source == deviceID && receiverCapabilities.contains(.controlResilienceV1):
            await beginRecovery(.recoveringReceiver(epoch: epoch, source: source, session: sessionID))
        case let .activating(_, target, _) where target == deviceID,
             let .controlling(_, target, _) where target == deviceID:
            await endCurrentSession(notifyPeer: false, reason: "controlling peer disconnected")
        case let .receiving(_, source, _) where source == deviceID:
            await endCurrentSession(notifyPeer: false, reason: "controller peer disconnected")
        default:
            break
        }
    }

    private func beginRecovery(_ recoveringState: State) async {
        setState(recoveringState)
        diagnostic("Session recovering; state=\(recoveringState)")
        activationInputTask?.cancel()
        activationInputTask = nil
        pointerFlushTask?.cancel()
        pointerFlushTask = nil
        pendingPointerEvent = nil
        pendingScrollEvent = nil
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        reliablePointerTask?.cancel()
        reliablePointerTask = nil
        realtimePointerCaptureSender.disable()
        realtimeInputReceiver.reset()
        progressReporter.reset()
        transport.setRealtimePeer(nil, role: .listener)
        for event in remoteInputState.releaseEvents() { injector.inject(event) }
        injector.releaseAll()
        pressedButtons.removeAll()
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: Self.sessionRecoveryTimeout) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            await self.expireRecovery(recoveringState)
        }
        await inputSender.cancelPending()
    }

    private func expireRecovery(_ expected: State) async {
        guard state == expected else { return }
        await endCurrentSession(notifyPeer: true, reason: "session recovery expired")
    }

    public func peerReconnected(_ peer: DeviceID) async {
        guard case let .recoveringController(epoch, target, previous) = state, target == peer else { return }
        let request = pendingResume ?? ControlSessionResume(previousSessionID: previous, sessionID: SessionID(), epoch: epoch)
        pendingResume = request
        try? await transport.send(ControlEnvelope(message: .resume(request)), to: target)
    }

    public func receiveResume(_ request: ControlSessionResume, from source: DeviceID) async {
        var accepted = false
        if receiverCapabilities.contains(.controlResilienceV1), election.currentEpoch == request.epoch,
           request.epoch.controllerID == source, request.sessionID != request.previousSessionID {
            switch state {
            case let .recoveringReceiver(epoch, peer, previous), let .receiving(epoch, peer, previous):
                guard epoch == request.epoch, peer == source else { break }
                if previous == request.sessionID && lastAcceptedResume == request {
                    accepted = true
                    break
                }
                guard previous == request.previousSessionID else { break }
                recoveryTask?.cancel()
                recoveryTask = nil
                for event in remoteInputState.releaseEvents() { injector.inject(event) }
                injector.releaseAll()
                lastReceivedInputSequence = nil
                realtimeInputReceiver.begin(epoch: epoch, source: source, sessionID: request.sessionID)
                lastHeartbeatNanos = clock.nowNanoseconds()
                lastAcceptedResume = request
                setState(.receiving(epoch: epoch, source: source, session: request.sessionID))
                transport.setRealtimePeer(source, role: .listener)
                startWatchdog(source: source, sessionID: request.sessionID)
                accepted = true
            default:
                break
            }
        }
        try? await transport.send(ControlEnvelope(message: .resumeResult(
            previousSessionID: request.previousSessionID, sessionID: request.sessionID, accepted: accepted
        )), to: source)
    }

    public func receiveResumeResult(previous: SessionID, sessionID: SessionID, accepted: Bool, from source: DeviceID) async {
        guard let request = pendingResume, request.previousSessionID == previous, request.sessionID == sessionID,
              case let .recoveringController(epoch, target, oldSession) = state,
              target == source, oldSession == previous else { return }
        guard accepted else {
            await endCurrentSession(notifyPeer: true, reason: "session resume rejected")
            return
        }
        recoveryTask?.cancel()
        recoveryTask = nil
        pendingResume = nil
        sequence = 0
        lastInputAcknowledgedSequence = nil
        pendingLaneProgress = nil
        inputOutstandingSinceNanos = nil
        reliableBarrierSequence = nil
        lastHeartbeatEchoNanos = nil
        resetRealtimeSender(incrementGeneration: true)
        resetRealtimeDelivery()
        realtimeDeliveryMode = activeControlRoute?.targetCapabilities.contains(.realtimePointerProgressV1) == true
            ? .probing : .reliableOnly
        setState(.controlling(epoch: epoch, target: target, session: sessionID))
        transport.setRealtimePeer(target, role: .dialer)
        await sendInput(.flags(rawValue: currentFlags))
        startHeartbeat(target: target, sessionID: sessionID)
        diagnostic("Session resumed; previous=\(previous), session=\(sessionID)")
    }

    @discardableResult
    public func receiveDeactivation(sessionID: SessionID, from source: DeviceID) async -> Bool {
        switch state {
        case let .activating(_, target, activeSessionID),
             let .controlling(_, target, activeSessionID),
             let .recoveringController(_, target, activeSessionID):
            guard target == source, activeSessionID == sessionID else {
                diagnostic("Ignoring stale deactivation for session \(sessionID) from \(source)")
                return false
            }
        case let .receiving(_, controller, activeSessionID),
             let .recoveringReceiver(_, controller, activeSessionID):
            guard controller == source, activeSessionID == sessionID else {
                diagnostic("Ignoring stale deactivation for session \(sessionID) from \(source)")
                return false
            }
        case .idle:
            return false
        }
        await endCurrentSession(notifyPeer: false, reason: "peer requested deactivation")
        return true
    }

    public func deactivateCurrentSession(reason: String = "explicit deactivation") async {
        await flushPendingMotion()
        _ = await inputSender.drainOrCancel(after: .milliseconds(50))
        await endCurrentSession(notifyPeer: true, reason: reason)
    }

    /// Waits until input already accepted by the coordinator has reached the
    /// transport. This is primarily useful at explicit session boundaries.
    public func flushPendingInput() async {
        await flushPendingMotion()
        await inputSender.drain()
        await reliablePointerTask?.value
    }

    public func stop() async {
        independentEventTask?.cancel()
        independentContinuation.finish()
        progressReporter.stop()
        await endCurrentSession(notifyPeer: true, reason: "coordinator stopped")
        capture.stop()
    }

    private func endCurrentSession(notifyPeer: Bool, reason: String) async {
        let previous = state
        let resumeToCancel = pendingResume
        recoveryTask?.cancel()
        recoveryTask = nil
        pendingResume = nil
        lastAcceptedResume = nil
        receiverCapabilities = []
        reliableBarrierSequence = nil
        pendingPointerCheckpoint = nil
        smoothedJitterNanos = nil
        lastInputAcknowledgedSequence = nil
        pendingLaneProgress = nil
        inputOutstandingSinceNanos = nil
        lastReceivedInputSequence = nil
        progressReporter.reset()
        diagnostic("Ending session; reason=\(reason), state=\(previous), notifyPeer=\(notifyPeer)")
        cancelPendingActivation()
        setState(.idle)
        activationInputTask?.cancel()
        activationInputTask = nil
        pointerFlushTask?.cancel()
        pointerFlushTask = nil
        reliablePointerTask?.cancel()
        reliablePointerTask = nil
        lastMotionFlushNanos = nil
        pendingPointerEvent = nil
        pendingScrollEvent = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        activeControlRoute = nil
        transport.setRealtimePeer(nil, role: .listener)
        currentFlags = 0
        smoothedHeartbeatIntervalNanos = nil
        smoothedRoundTripNanos = nil
        lastHeartbeatEchoNanos = nil
        pressedButtons.removeAll()
        resetRealtimeSender(incrementGeneration: true)
        resetRealtimeReceiver()
        resetRealtimeDelivery()
        capture.setSuppressionEnabled(false)

        if case .receiving = previous {
            for event in remoteInputState.releaseEvents() {
                injector.inject(event)
            }
            injector.releaseAll()
        }
        await inputSender.cancelPending()

        switch previous {
        case let .activating(_, target, sessionID),
             let .controlling(_, target, sessionID),
             let .recoveringController(_, target, sessionID):
            if notifyPeer {
                if let resumeToCancel {
                    try? await transport.send(ControlEnvelope(message: .deactivate(resumeToCancel.sessionID)), to: target)
                }
                try? await transport.send(ControlEnvelope(message: .releaseAll(sessionID)), to: target)
                try? await transport.send(ControlEnvelope(message: .deactivate(sessionID)), to: target)
            }
        case let .receiving(_, source, sessionID),
             let .recoveringReceiver(_, source, sessionID):
            if notifyPeer {
                try? await transport.send(ControlEnvelope(message: .deactivate(sessionID)), to: source)
            }
        case .idle:
            break
        }
    }

    private func setState(_ value: State) {
        state = value
        publishSessionSnapshotIfChanged()
    }

    private func publishSessionSnapshotIfChanged() {
        let latency = smoothedRoundTripNanos
            .map { Int($0 / 1_000_000) }
            .flatMap { $0 >= 30 ? 30 : nil }
        let snapshot: ControlSessionSnapshot
        switch state {
        case .idle:
            snapshot = .idle
        case let .activating(_, target, _):
            snapshot = .init(phase: .activating, peerID: target, latencyMilliseconds: latency)
        case let .controlling(_, target, _):
            snapshot = .init(phase: .controlling, peerID: target, latencyMilliseconds: latency)
        case let .receiving(_, source, _):
            snapshot = .init(phase: .receiving, peerID: source)
        case let .recoveringController(_, peer, _), let .recoveringReceiver(_, peer, _):
            snapshot = .init(phase: .recovering, peerID: peer)
        }
        guard snapshot != lastSessionSnapshot else { return }
        lastSessionSnapshot = snapshot
        sessionContinuation.yield(snapshot)
    }

    private func beginActivationWait(
        target: DeviceID,
        sessionID: SessionID,
        timeout: Duration
    ) -> AsyncStream<ActivationOutcome> {
        cancelPendingActivation()
        let pair = AsyncStream<ActivationOutcome>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pendingActivation = PendingActivation(
            target: target,
            sessionID: sessionID,
            continuation: pair.continuation
        )
        activationTimeoutTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: timeout) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            await self.finishPendingActivation(
                target: target,
                sessionID: sessionID,
                outcome: .timedOut
            )
        }
        return pair.stream
    }

    private func firstActivationOutcome(
        from stream: AsyncStream<ActivationOutcome>
    ) async -> ActivationOutcome {
        for await outcome in stream { return outcome }
        return .rejected
    }

    @discardableResult
    private func finishPendingActivation(
        target: DeviceID,
        sessionID: SessionID,
        outcome: ActivationOutcome
    ) -> Bool {
        guard let pendingActivation,
              pendingActivation.target == target,
              pendingActivation.sessionID == sessionID else { return false }
        self.pendingActivation = nil
        activationTimeoutTask?.cancel()
        activationTimeoutTask = nil
        pendingActivation.continuation.yield(outcome)
        pendingActivation.continuation.finish()
        return true
    }

    private func cancelPendingActivation() {
        guard let pendingActivation else { return }
        self.pendingActivation = nil
        activationTimeoutTask?.cancel()
        activationTimeoutTask = nil
        pendingActivation.continuation.yield(.rejected)
        pendingActivation.continuation.finish()
    }

    private static func isEmergencyStop(_ event: InputEvent, flags: UInt64) -> Bool {
        guard case let .key(code, isDown, _) = event, isDown, code == emergencyKeyCode else { return false }
        return (flags & emergencyFlags) == emergencyFlags
    }

    private func flushPendingMotionIfDue() async {
        let now = clock.nowNanoseconds()
        guard let lastMotionFlushNanos,
              now >= lastMotionFlushNanos,
              now - lastMotionFlushNanos < pointerBatchIntervalNanos else {
            await flushPendingMotion()
            return
        }
        schedulePointerFlush(after: pointerBatchIntervalNanos - (now - lastMotionFlushNanos))
    }

    private func schedulePointerFlush(after delayNanoseconds: UInt64) {
        guard pointerFlushTask == nil else { return }
        pointerFlushTask = Task(priority: realtimeInputTaskPriority) { [weak self, clock] in
            try? await clock.sleep(for: .nanoseconds(Int64(delayNanoseconds)))
            guard !Task.isCancelled else { return }
            await self?.scheduledPointerFlushFired()
        }
    }

    private func flushPendingMotion() async {
        pointerFlushTask?.cancel()
        pointerFlushTask = nil
        await sendPendingMotion()
    }

    private func scheduledPointerFlushFired() async {
        pointerFlushTask = nil
        await sendPendingMotion()
    }

    private func sendPendingMotion() async {
        let pointer = pendingPointerEvent
        let scroll = pendingScrollEvent
        pendingPointerEvent = nil
        pendingScrollEvent = nil
        guard pointer != nil || scroll != nil else { return }
        lastMotionFlushNanos = clock.nowNanoseconds()
        if let pointer { await sendPointer(pointer) }
        if let scroll { await sendInput(scroll) }
    }

    private func sendPointer(_ event: InputEvent) async {
        guard case let .pointerMove(deltaX, deltaY, absoluteX, absoluteY) = event,
              case let .controlling(epoch, target, sessionID) = state else { return }
        if reliableBarrierSequence != nil {
            await sendReliablePointer(event)
            return
        }
        switch realtimeDeliveryMode {
        case .reliableOnly:
            await sendReliablePointer(event)
            return
        case .probing, .fallback:
            await sendRealtimeProbe(
                epoch: epoch,
                target: target,
                sessionID: sessionID,
                absoluteX: absoluteX,
                absoluteY: absoluteY
            )
            await sendReliablePointer(event)
            return
        case .healthy:
            if realtimePointerCaptureSender.send(event) { return }
            enterRealtimeFallback(target: target)
            await sendReliablePointer(event)
            await sendRealtimeProbe(
                epoch: epoch,
                target: target,
                sessionID: sessionID,
                absoluteX: absoluteX,
                absoluteY: absoluteY
            )
            return
        case .legacy:
            break
        }
        cumulativePointerX += deltaX
        cumulativePointerY += deltaY
        let frame = RealtimePointerFrame(
            workspaceID: workspaceID,
            sessionID: sessionID,
            controllerID: localDeviceID,
            epoch: epoch,
            generation: realtimeGeneration,
            sequence: realtimeSequence,
            deltaX: deltaX,
            deltaY: deltaY,
            cumulativeDeltaX: cumulativePointerX,
            cumulativeDeltaY: cumulativePointerY,
            absoluteX: absoluteX,
            absoluteY: absoluteY,
            timestampNanos: clock.nowNanoseconds()
        )
        realtimeSequence &+= 1
        do {
            let usedRealtime = try await transport.sendRealtime(frame, to: target)
            if usedRealtime {
                lastRealtimeSentSequence = frame.sequence
            } else if realtimeDeliveryMode == .legacy {
                resetRealtimeSender(incrementGeneration: true)
                await sendReliablePointer(event)
            } else {
                enterRealtimeFallback(target: target)
                await sendReliablePointer(event)
            }
        } catch {
            if realtimeDeliveryMode == .legacy {
                resetRealtimeSender(incrementGeneration: true)
            } else {
                enterRealtimeFallback(target: target)
            }
            await sendReliablePointer(event)
        }
    }

    private func sendRealtimeProbe(
        epoch: ControllerEpoch,
        target: DeviceID,
        sessionID: SessionID,
        absoluteX: Double,
        absoluteY: Double
    ) async {
        let now = clock.nowNanoseconds()
        if let lastRealtimeProbeNanos,
           now >= lastRealtimeProbeNanos,
           now - lastRealtimeProbeNanos < Self.realtimeProbeIntervalNanos { return }
        let frame = RealtimePointerFrame(
            workspaceID: workspaceID,
            sessionID: sessionID,
            controllerID: localDeviceID,
            epoch: epoch,
            generation: realtimeGeneration,
            sequence: realtimeSequence,
            deltaX: 0,
            deltaY: 0,
            cumulativeDeltaX: cumulativePointerX,
            cumulativeDeltaY: cumulativePointerY,
            absoluteX: absoluteX,
            absoluteY: absoluteY,
            timestampNanos: now
        )
        realtimeSequence &+= 1
        do {
            guard try await transport.sendRealtime(frame, to: target) else { return }
            lastRealtimeProbeNanos = now
            lastRealtimeSentSequence = frame.sequence
        } catch {
            // Reliable input remains active while the lane reconnects.
        }
    }

    private func sendReliablePointer(_ event: InputEvent) async {
        guard case let .controlling(_, target, sessionID) = state else { return }
        await sendInput(event)
        guard case let .controlling(_, currentTarget, currentSessionID) = state,
              currentTarget == target, currentSessionID == sessionID else { return }
        reliablePointerRevision &+= 1
        guard reliablePointerTask == nil else { return }
        reliablePointerTask = Task { [weak self] in
            await self?.monitorReliablePointer(target: target, sessionID: sessionID)
        }
    }

    private func monitorReliablePointer(target: DeviceID, sessionID: SessionID) async {
        while !Task.isCancelled {
            let revision = reliablePointerRevision
            await checkReliablePointerDelivery(target: target, sessionID: sessionID)
            guard !Task.isCancelled else { return }
            // Input can arrive while the drain completes. Keep monitoring that
            // new work without making the capture consumer wait for the socket.
            if revision == reliablePointerRevision {
                reliablePointerTask = nil
                return
            }
        }
    }

    private func checkReliablePointerDelivery(target: DeviceID, sessionID: SessionID) async {
        let delivered = await inputSender.drainOrCancel(after: Self.reliablePointerTimeout)
        guard !Task.isCancelled, !delivered else { return }
        diagnostic("Reliable pointer timed out for session \(sessionID); mode=\(realtimeDeliveryMode)")
        guard case let .controlling(_, currentTarget, currentSessionID) = state,
              currentTarget == target, currentSessionID == sessionID else { return }
        if realtimeDeliveryMode == .healthy,
           realtimePointerCaptureSender.hasFreshAcknowledgement() {
            diagnostic("Keeping session \(sessionID); realtime progress is fresh")
            return
        }
        let now = clock.nowNanoseconds()
        if let lastHeartbeatEchoNanos,
           now >= lastHeartbeatEchoNanos,
           now - lastHeartbeatEchoNanos <= Self.minimumHeartbeatTimeoutNanos {
            diagnostic("Keeping session \(sessionID); control heartbeat is fresh")
            if activeControlRoute?.targetCapabilities.contains(.realtimePointerProgressV1) == true {
                enterRealtimeFallback(target: target)
            }
            return
        }
        await endCurrentSession(notifyPeer: false, reason: "reliable pointer delivery timed out")
    }

    private func enterRealtimeFallback(target: DeviceID) {
        guard realtimeDeliveryMode != .fallback else { return }
        if supportsResilience {
            pendingPointerCheckpoint = realtimePointerCaptureSender.takeCheckpoint(reliableSequence: sequence)
        }
        realtimePointerCaptureSender.disable()
        resetRealtimeSender(incrementGeneration: true)
        lastRealtimeSentSequence = nil
        lastRealtimeProbeNanos = nil
        realtimeDeliveryMode = .fallback
        diagnostic("Realtime pointer entered fallback for peer \(target); generation=\(realtimeGeneration)")
        transport.reconnectRealtime(to: target)
    }

    private func resetRealtimeSender(incrementGeneration: Bool) {
        realtimePointerCaptureSender.disable()
        if incrementGeneration { realtimeGeneration &+= 1 }
        realtimeSequence = 0
        cumulativePointerX = 0
        cumulativePointerY = 0
    }

    private func resetRealtimeReceiver() {
        realtimeInputReceiver.reset()
    }

    private func resetRealtimeDelivery() {
        realtimePointerCaptureSender.disable()
        realtimeDeliveryMode = .legacy
        lastRealtimeSentSequence = nil
        lastRealtimeProbeNanos = nil
    }

    private func startHeartbeat(target: DeviceID, sessionID: SessionID) {
        heartbeatTask?.cancel()
        let interval = activeControlRoute?.targetCapabilities.contains(.realtimePointerProgressV1) == true
            ? Self.realtimeHeartbeatInterval
            : .seconds(1)
        diagnostic("Heartbeat started for session \(sessionID); interval=\(interval)")
        heartbeatTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                try? await clock.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.sendHeartbeat(target: target, sessionID: sessionID)
            }
        }
    }

    private func sendHeartbeat(target: DeviceID, sessionID: SessionID) async {
        guard case let .controlling(_, expectedTarget, expectedSession) = state,
              target == expectedTarget, sessionID == expectedSession else { return }
        if supportsResilience, realtimePointerCaptureSender.hasExpiredOutstandingMotion() {
            // Flush the final cumulative movement even when capture has gone idle.
            await sendInput(.flags(rawValue: currentFlags))
        }
        if supportsResilience, let outstanding = inputOutstandingSinceNanos,
           clock.nowNanoseconds() >= outstanding,
           clock.nowNanoseconds() - outstanding > Self.inputProgressTimeoutNanos {
            await endCurrentSession(notifyPeer: true, reason: "receiver input progress expired")
            return
        }
        do {
            try await transport.send(
                ControlEnvelope(message: .heartbeat(sessionID: sessionID, timestampNanos: clock.nowNanoseconds())),
                to: target
            )
        } catch {
            diagnostic("Heartbeat send failed for session \(sessionID): \(error.localizedDescription)")
        }
    }

    private func startWatchdog(source: DeviceID, sessionID: SessionID) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let expired = await self.isHeartbeatExpired(source: source, sessionID: sessionID)
                if expired {
                    await self.deactivateCurrentSession(reason: "receiver heartbeat expired")
                    return
                }
            }
        }
    }

    private func isHeartbeatExpired(source: DeviceID, sessionID: SessionID) -> Bool {
        guard case let .receiving(_, expectedSource, expectedSession) = state,
              source == expectedSource, sessionID == expectedSession else { return false }
        let adaptiveTimeout = smoothedHeartbeatIntervalNanos.map {
            min(max(min($0, Self.maximumHeartbeatTimeoutNanos / 8) * 8,
                    Self.minimumHeartbeatTimeoutNanos),
                Self.maximumHeartbeatTimeoutNanos)
        } ?? Self.heartbeatTimeoutNanos
        return clock.nowNanoseconds() &- lastHeartbeatNanos > adaptiveTimeout
    }

    private static func smoothed(previous: UInt64?, sample: UInt64) -> UInt64 {
        guard let previous else { return sample }
        return (previous &* 7 &+ sample) / 8
    }

}

/// Preserves reliable input ordering without letting a slow network send block
/// the coordinator's heartbeat and reconnect state machine.
actor OrderedInputSender {
    private struct PendingFrame: Sendable {
        let frame: InputFrame
        let target: DeviceID
        let checkpoint: PointerCheckpoint?
        let enqueuedAtNanos: UInt64
    }

    static let maximumPendingFrames = 256
    private let transport: PeerTransport
    private let clock: MonotonicClock
    private var pending: [PendingFrame] = []
    private var nextIndex = 0
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var failedGeneration: UInt64?
    private var acceptedFrames: UInt64 = 0
    private var sentFrames: UInt64 = 0
    private var coalescedFrames: UInt64 = 0
    private var maximumPendingDepth = 0

    func snapshot() -> InputQueueSnapshot {
        let now = clock.nowNanoseconds()
        let oldest = nextIndex < pending.count ? pending[nextIndex].enqueuedAtNanos : now
        return InputQueueSnapshot(acceptedFrames: acceptedFrames, sentFrames: sentFrames,
            coalescedFrames: coalescedFrames, pendingFrames: pending.count - nextIndex,
            maximumPendingFrames: maximumPendingDepth,
            oldestPendingAgeNanoseconds: now >= oldest ? now - oldest : 0)
    }

    init(transport: PeerTransport, clock: MonotonicClock) {
        self.transport = transport
        self.clock = clock
    }

    @discardableResult
    func enqueue(_ frame: InputFrame, to target: DeviceID, checkpoint: PointerCheckpoint? = nil) -> Bool {
        if worker == nil, failedGeneration == generation {
            // A completed failed batch must not poison later successful sends.
            generation &+= 1
        }
        if checkpoint == nil, pending.count > nextIndex,
           let previous = pending.last, previous.checkpoint == nil,
           previous.target == target,
           previous.frame.workspaceID == frame.workspaceID,
           previous.frame.sessionID == frame.sessionID,
           previous.frame.epoch == frame.epoch,
           case let .pointerMove(previousX, previousY, _, _) = previous.frame.event,
           case let .pointerMove(deltaX, deltaY, absoluteX, absoluteY) = frame.event {
            // Only adjacent, unsent motion can be replaced. Keys and buttons
            // remain ordering barriers, including the start and end of a drag.
            let merged = InputFrame(
                workspaceID: frame.workspaceID, sessionID: frame.sessionID,
                controllerID: frame.controllerID, epoch: frame.epoch,
                sequence: frame.sequence, timestampNanos: frame.timestampNanos,
                event: .pointerMove(deltaX: previousX + deltaX, deltaY: previousY + deltaY,
                                    absoluteX: absoluteX, absoluteY: absoluteY)
            )
            pending[pending.count - 1] = PendingFrame(frame: merged, target: target, checkpoint: nil, enqueuedAtNanos: previous.enqueuedAtNanos)
            coalescedFrames &+= 1
        } else {
            guard pending.count - nextIndex < Self.maximumPendingFrames else {
                cancelPending()
                failedGeneration = generation
                return false
            }
            pending.append(PendingFrame(frame: frame, target: target, checkpoint: checkpoint, enqueuedAtNanos: clock.nowNanoseconds()))
        }
        acceptedFrames &+= 1
        maximumPendingDepth = max(maximumPendingDepth, pending.count - nextIndex)
        guard worker == nil else { return true }
        let activeGeneration = generation
        worker = Task { [weak self] in
            await self?.sendPendingFrames(generation: activeGeneration)
        }
        return true
    }

    func cancelPending() {
        generation &+= 1
        pending.removeAll(keepingCapacity: true)
        nextIndex = 0
        worker?.cancel()
        worker = nil
        resumeDrainWaiters()
    }

    func drain() async {
        guard worker != nil || nextIndex < pending.count else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    func drainOrCancel(after timeout: Duration) async -> Bool {
        guard worker != nil || nextIndex < pending.count else {
            return failedGeneration != generation
        }
        let activeGeneration = generation
        let timeoutTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            await self?.cancelPending(generation: activeGeneration)
        }
        await drain()
        timeoutTask.cancel()
        return generation == activeGeneration && failedGeneration != activeGeneration
    }

    private func sendPendingFrames(generation activeGeneration: UInt64) async {
        while !Task.isCancelled, generation == activeGeneration {
            guard nextIndex < pending.count else {
                pending.removeAll(keepingCapacity: true)
                nextIndex = 0
                if generation == activeGeneration {
                    worker = nil
                    resumeDrainWaiters()
                }
                return
            }

            let item = pending[nextIndex]
            nextIndex += 1
            do {
                if let checkpoint = item.checkpoint {
                    try await transport.send(ControlEnvelope(message: .pointerCheckpoint(checkpoint)), to: item.target)
                    guard !Task.isCancelled, generation == activeGeneration else { return }
                }
                try await transport.send(item.frame, to: item.target)
            } catch {
                guard !Task.isCancelled, generation == activeGeneration else { return }
                failedGeneration = activeGeneration
                pending.removeAll(keepingCapacity: true)
                nextIndex = 0
                worker = nil
                resumeDrainWaiters()
                return
            }
            guard !Task.isCancelled, generation == activeGeneration else { return }
            sentFrames &+= 1

            if nextIndex >= 64, nextIndex * 2 >= pending.count {
                pending.removeFirst(nextIndex)
                nextIndex = 0
            }
        }
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    private func cancelPending(generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration else { return }
        cancelPending()
    }
}
