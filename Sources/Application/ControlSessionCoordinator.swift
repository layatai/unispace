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
        case controlling(epoch: ControllerEpoch, target: DeviceID, session: SessionID)
        case receiving(epoch: ControllerEpoch, source: DeviceID, session: SessionID)
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

    private let localDeviceID: DeviceID
    private let workspaceID: WorkspaceID
    private let capture: InputCapture
    private let injector: InputInjector
    private let transport: PeerTransport
    private let inputSender: OrderedInputSender
    private let clock: MonotonicClock
    private let activationTimeout: Duration
    private var election: ControllerStateMachine
    private var remoteInputState = RemoteInputState()
    private var currentFlags: UInt64 = 0
    private var sequence: UInt64 = 0
    private var realtimeGeneration: UInt64 = 0
    private var realtimeSequence: UInt64 = 0
    private var cumulativePointerX: Double = 0
    private var cumulativePointerY: Double = 0
    private var receivedRealtimeGeneration: UInt64?
    private var receivedRealtimeSequence: UInt64?
    private var receivedCumulativePointerX: Double = 0
    private var receivedCumulativePointerY: Double = 0
    private var pressedButtons: Set<PointerButton> = []
    private var state: State = .idle
    private var pendingPointerEvent: InputEvent?
    private var pendingScrollEvent: InputEvent?
    private var pointerFlushTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastHeartbeatNanos: UInt64 = 0
    private var smoothedHeartbeatIntervalNanos: UInt64?
    private var smoothedRoundTripNanos: UInt64?
    private var activeControlRoute: ActiveControlRoute?
    private var pendingActivation: PendingActivation?
    private var activationTimeoutTask: Task<Void, Never>?

    public init(
        localDeviceID: DeviceID,
        workspaceID: WorkspaceID,
        capture: InputCapture,
        injector: InputInjector,
        transport: PeerTransport,
        clock: MonotonicClock = SystemMonotonicClock(),
        activationTimeout: Duration = .seconds(2),
        election: ControllerStateMachine = .init()
    ) {
        precondition(activationTimeout > .zero)
        self.localDeviceID = localDeviceID
        self.workspaceID = workspaceID
        self.capture = capture
        self.injector = injector
        self.transport = transport
        self.inputSender = OrderedInputSender(transport: transport)
        self.clock = clock
        self.activationTimeout = activationTimeout
        self.election = election
    }

    public func currentState() -> State { state }

    @discardableResult
    public func makeLocalController() async -> ControllerEpoch {
        let epoch = election.claim(for: localDeviceID)
        await endCurrentSession(notifyPeer: true)
        state = .idle
        return epoch
    }

    public func observeControllerClaim(_ epoch: ControllerEpoch) async {
        guard election.observe(epoch) else { return }
        if epoch.controllerID != localDeviceID {
            await endCurrentSession(notifyPeer: false)
        }
    }

    public func activate(
        target: DeviceID,
        displayID: DisplayID,
        entryEdge: DisplayEdge,
        normalizedPosition: Double,
        targetCapabilities: Set<DeviceCapability> = [],
        requiresActivationConfirmation: Bool = false,
        initialEvent: InputEvent? = nil
    ) async throws {
        guard let epoch = election.currentEpoch, epoch.controllerID == localDeviceID else { return }
        if case .idle = state {
            // Input capture may already be synchronously pre-armed by the edge event tap.
        } else {
            await endCurrentSession(notifyPeer: true)
        }
        let sessionID = SessionID()
        resetRealtimeSender(incrementGeneration: true)
        state = .controlling(epoch: epoch, target: target, session: sessionID)
        activeControlRoute = ActiveControlRoute(
            target: target,
            displayID: displayID,
            entryEdge: entryEdge,
            normalizedPosition: normalizedPosition,
            targetCapabilities: targetCapabilities
        )
        capture.setSuppressionEnabled(true)
        let supportsExplicitAcknowledgement = targetCapabilities.contains(.activationAcknowledgementV1)
        let activationResults = (requiresActivationConfirmation || supportsExplicitAcknowledgement)
            ? beginActivationWait(target: target, sessionID: sessionID)
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
            if let initialEvent {
                _ = await handleCaptured(initialEvent)
            }
            if let activationResults {
                if !supportsExplicitAcknowledgement {
                    await sendHeartbeat(target: target, sessionID: sessionID)
                    startHeartbeat(target: target, sessionID: sessionID)
                }
                switch await firstActivationOutcome(from: activationResults) {
                case .accepted:
                    break
                case .rejected:
                    throw ActivationError.rejected
                case .timedOut:
                    throw ActivationError.timedOut
                }
                if supportsExplicitAcknowledgement {
                    startHeartbeat(target: target, sessionID: sessionID)
                }
            } else {
                startHeartbeat(target: target, sessionID: sessionID)
            }
        } catch {
            await endCurrentSession(notifyPeer: false)
            throw error
        }
    }

    @discardableResult
    public func receiveActivationResult(
        sessionID: SessionID,
        from source: DeviceID,
        accepted: Bool
    ) -> Bool {
        finishPendingActivation(
            target: source,
            sessionID: sessionID,
            outcome: accepted ? .accepted : .rejected
        )
    }

    public func receiveActivation(
        _ activation: InputActivation,
        from source: DeviceID,
        targetDisplay: DisplayDescriptor?,
        isInputInjectionAuthorized: Bool = true
    ) async -> Bool {
        let epoch = activation.epoch
        guard election.currentEpoch == epoch,
              epoch.controllerID == source,
              isInputInjectionAuthorized,
              let targetDisplay,
              targetDisplay.id == activation.targetDisplayID,
              targetDisplay.deviceID == localDeviceID else { return false }
        await endCurrentSession(notifyPeer: false)
        injector.activate(
            on: targetDisplay,
            enteringFrom: activation.entryEdge,
            normalizedPosition: activation.normalizedPosition
        )
        state = .receiving(epoch: epoch, source: source, session: activation.sessionID)
        lastHeartbeatNanos = clock.nowNanoseconds()
        startWatchdog(source: source, sessionID: activation.sessionID)
        return true
    }

    public func handleCaptured(_ event: InputEvent) async -> CapturedInputDisposition {
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
            await endCurrentSession(notifyPeer: true)
            return .emergencyStop
        }
        if case let .mouseButton(button, isDown, _) = event {
            await flushPendingMotion()
            if isDown { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
            await sendInput(event)
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
            schedulePointerFlush()
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
            schedulePointerFlush()
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
        smoothedRoundTripNanos = Self.smoothed(
            previous: smoothedRoundTripNanos,
            sample: now - sentAtNanos
        )
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
        await inputSender.enqueue(frame, to: target)
    }

    public func handleIncoming(_ frame: InputFrame, from source: DeviceID) async {
        guard election.accepts(frame), frame.controllerID == source else { return }
        guard case let .receiving(epoch, expectedSource, sessionID) = state,
              epoch == frame.epoch,
              expectedSource == source,
              sessionID == frame.sessionID else { return }
        remoteInputState.apply(frame.event)
        injector.inject(frame.event)
    }

    public func handleIncomingRealtime(_ frame: RealtimePointerFrame, from source: DeviceID) {
        guard frame.workspaceID == workspaceID,
              election.currentEpoch == frame.epoch,
              frame.controllerID == source,
              case let .receiving(epoch, expectedSource, sessionID) = state,
              epoch == frame.epoch,
              expectedSource == source,
              sessionID == frame.sessionID else { return }

        if let receivedRealtimeGeneration, frame.generation < receivedRealtimeGeneration { return }
        if receivedRealtimeGeneration != frame.generation {
            receivedRealtimeGeneration = frame.generation
            receivedRealtimeSequence = nil
            receivedCumulativePointerX = 0
            receivedCumulativePointerY = 0
        }
        guard receivedRealtimeSequence.map({ frame.sequence > $0 }) ?? true else { return }
        let deltaX = frame.cumulativeDeltaX - receivedCumulativePointerX
        let deltaY = frame.cumulativeDeltaY - receivedCumulativePointerY
        receivedRealtimeSequence = frame.sequence
        receivedCumulativePointerX = frame.cumulativeDeltaX
        receivedCumulativePointerY = frame.cumulativeDeltaY
        injector.inject(.pointerMove(
            deltaX: deltaX,
            deltaY: deltaY,
            absoluteX: frame.absoluteX,
            absoluteY: frame.absoluteY
        ))
    }

    public func peerDisconnected(_ deviceID: DeviceID) async {
        switch state {
        case let .controlling(_, target, _) where target == deviceID:
            await endCurrentSession(notifyPeer: false)
        case let .receiving(_, source, _) where source == deviceID:
            await endCurrentSession(notifyPeer: false)
        default:
            break
        }
    }

    public func deactivateCurrentSession() async {
        await flushPendingMotion()
        await inputSender.drainOrCancel(after: .milliseconds(50))
        await endCurrentSession(notifyPeer: true)
    }

    /// Waits until input already accepted by the coordinator has reached the
    /// transport. This is primarily useful at explicit session boundaries.
    func flushPendingInput() async {
        await flushPendingMotion()
        await inputSender.drain()
    }

    public func stop() async {
        await endCurrentSession(notifyPeer: true)
        capture.stop()
    }

    private func endCurrentSession(notifyPeer: Bool) async {
        let previous = state
        cancelPendingActivation()
        state = .idle
        pointerFlushTask?.cancel()
        pointerFlushTask = nil
        pendingPointerEvent = nil
        pendingScrollEvent = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        activeControlRoute = nil
        currentFlags = 0
        smoothedHeartbeatIntervalNanos = nil
        smoothedRoundTripNanos = nil
        pressedButtons.removeAll()
        resetRealtimeSender(incrementGeneration: true)
        resetRealtimeReceiver()
        capture.setSuppressionEnabled(false)

        if case .receiving = previous {
            for event in remoteInputState.releaseEvents() {
                injector.inject(event)
            }
            injector.releaseAll()
        }
        await inputSender.cancelPending()

        switch previous {
        case let .controlling(_, target, sessionID):
            if notifyPeer {
                try? await transport.send(ControlEnvelope(message: .releaseAll(sessionID)), to: target)
                try? await transport.send(ControlEnvelope(message: .deactivate(sessionID)), to: target)
            }
        case let .receiving(_, source, sessionID):
            if notifyPeer {
                try? await transport.send(ControlEnvelope(message: .deactivate(sessionID)), to: source)
            }
        case .idle:
            break
        }
    }

    private func beginActivationWait(
        target: DeviceID,
        sessionID: SessionID
    ) -> AsyncStream<ActivationOutcome> {
        cancelPendingActivation()
        let pair = AsyncStream<ActivationOutcome>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pendingActivation = PendingActivation(
            target: target,
            sessionID: sessionID,
            continuation: pair.continuation
        )
        let timeout = activationTimeout
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

    private func schedulePointerFlush() {
        guard pointerFlushTask == nil else { return }
        pointerFlushTask = Task { [weak self, clock] in
            try? await clock.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            await self?.flushPendingMotion()
        }
    }

    private func flushPendingMotion() async {
        pointerFlushTask?.cancel()
        pointerFlushTask = nil
        let pointer = pendingPointerEvent
        let scroll = pendingScrollEvent
        pendingPointerEvent = nil
        pendingScrollEvent = nil
        if let pointer { await sendPointer(pointer) }
        if let scroll { await sendInput(scroll) }
    }

    private func sendPointer(_ event: InputEvent) async {
        guard case let .pointerMove(deltaX, deltaY, absoluteX, absoluteY) = event,
              case let .controlling(epoch, target, sessionID) = state else { return }
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
            if !usedRealtime {
                resetRealtimeSender(incrementGeneration: true)
            }
        } catch {
            resetRealtimeSender(incrementGeneration: true)
        }
    }

    private func resetRealtimeSender(incrementGeneration: Bool) {
        if incrementGeneration { realtimeGeneration &+= 1 }
        realtimeSequence = 0
        cumulativePointerX = 0
        cumulativePointerY = 0
    }

    private func resetRealtimeReceiver() {
        receivedRealtimeGeneration = nil
        receivedRealtimeSequence = nil
        receivedCumulativePointerX = 0
        receivedCumulativePointerY = 0
    }

    private func startHeartbeat(target: DeviceID, sessionID: SessionID) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await self.sendHeartbeat(target: target, sessionID: sessionID)
            }
        }
    }

    private func sendHeartbeat(target: DeviceID, sessionID: SessionID) async {
        guard case let .controlling(_, expectedTarget, expectedSession) = state,
              target == expectedTarget, sessionID == expectedSession else { return }
        try? await transport.send(
            ControlEnvelope(message: .heartbeat(sessionID: sessionID, timestampNanos: clock.nowNanoseconds())),
            to: target
        )
    }

    private func startWatchdog(source: DeviceID, sessionID: SessionID) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let expired = await self.isHeartbeatExpired(source: source, sessionID: sessionID)
                if expired {
                    await self.deactivateCurrentSession()
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
private actor OrderedInputSender {
    private struct PendingFrame: Sendable {
        let frame: InputFrame
        let target: DeviceID
    }

    private let transport: PeerTransport
    private var pending: [PendingFrame] = []
    private var nextIndex = 0
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(transport: PeerTransport) {
        self.transport = transport
    }

    func enqueue(_ frame: InputFrame, to target: DeviceID) {
        pending.append(PendingFrame(frame: frame, target: target))
        guard worker == nil else { return }
        let activeGeneration = generation
        worker = Task { [weak self] in
            await self?.sendPendingFrames(generation: activeGeneration)
        }
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

    func drainOrCancel(after timeout: Duration) async {
        guard worker != nil || nextIndex < pending.count else { return }
        let activeGeneration = generation
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.cancelPending(generation: activeGeneration)
        }
        await drain()
        timeoutTask.cancel()
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
            try? await transport.send(item.frame, to: item.target)
            guard !Task.isCancelled, generation == activeGeneration else { return }

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
