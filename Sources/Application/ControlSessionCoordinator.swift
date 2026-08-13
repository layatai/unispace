import Foundation
import UniSpaceDomain

public actor ControlSessionCoordinator {
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

    public static let emergencyKeyCode: UInt16 = 53
    public static let emergencyFlags: UInt64 = 0x0014_0000 | 0x0008_0000 | 0x0004_0000

    private let localDeviceID: DeviceID
    private let workspaceID: WorkspaceID
    private let capture: InputCapture
    private let injector: InputInjector
    private let transport: PeerTransport
    private let clock: MonotonicClock
    private var election: ControllerStateMachine
    private var remoteInputState = RemoteInputState()
    private var currentFlags: UInt64 = 0
    private var sequence: UInt64 = 0
    private var state: State = .idle
    private var pendingPointerEvent: InputEvent?
    private var pointerFlushTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastHeartbeatNanos: UInt64 = 0

    public init(
        localDeviceID: DeviceID,
        workspaceID: WorkspaceID,
        capture: InputCapture,
        injector: InputInjector,
        transport: PeerTransport,
        clock: MonotonicClock = SystemMonotonicClock(),
        election: ControllerStateMachine = .init()
    ) {
        self.localDeviceID = localDeviceID
        self.workspaceID = workspaceID
        self.capture = capture
        self.injector = injector
        self.transport = transport
        self.clock = clock
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

    public func activate(target: DeviceID, displayID: DisplayID, entryEdge: DisplayEdge, normalizedPosition: Double) async throws {
        guard let epoch = election.currentEpoch, epoch.controllerID == localDeviceID else { return }
        await endCurrentSession(notifyPeer: true)
        let sessionID = SessionID()
        state = .controlling(epoch: epoch, target: target, session: sessionID)
        capture.setSuppressionEnabled(true)
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
            startHeartbeat(target: target, sessionID: sessionID)
        } catch {
            await endCurrentSession(notifyPeer: false)
            throw error
        }
    }

    public func receiveActivation(
        _ activation: InputActivation,
        from source: DeviceID,
        targetDisplay: DisplayDescriptor?
    ) async -> Bool {
        let epoch = activation.epoch
        guard election.currentEpoch == epoch, epoch.controllerID == source else { return false }
        await endCurrentSession(notifyPeer: false)
        if let targetDisplay {
            injector.activate(
                on: targetDisplay,
                enteringFrom: activation.entryEdge,
                normalizedPosition: activation.normalizedPosition
            )
        }
        state = .receiving(epoch: epoch, source: source, session: activation.sessionID)
        lastHeartbeatNanos = clock.nowNanoseconds()
        startWatchdog(source: source, sessionID: activation.sessionID)
        return true
    }

    public func handleCaptured(_ event: InputEvent) async -> CapturedInputDisposition {
        guard case .controlling = state else { return .ignored }
        if case let .flags(rawValue) = event {
            currentFlags = rawValue
        }
        if Self.isEmergencyStop(event, flags: currentFlags) {
            await endCurrentSession(notifyPeer: true)
            return .emergencyStop
        }
        if case let .pointerMove(deltaX, deltaY, absoluteX, absoluteY) = event {
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
        await flushPendingPointer()
        await sendInput(event)
        return .forwarded
    }

    public func receiveHeartbeat(sessionID: SessionID, from source: DeviceID) {
        guard case let .receiving(_, expectedSource, expectedSession) = state,
              source == expectedSource, sessionID == expectedSession else { return }
        lastHeartbeatNanos = clock.nowNanoseconds()
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
        do {
            try await transport.send(frame, to: target)
        } catch {
            await endCurrentSession(notifyPeer: false)
        }
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
        await endCurrentSession(notifyPeer: true)
    }

    public func stop() async {
        await endCurrentSession(notifyPeer: true)
        capture.stop()
    }

    private func endCurrentSession(notifyPeer: Bool) async {
        let previous = state
        state = .idle
        pointerFlushTask?.cancel()
        pointerFlushTask = nil
        pendingPointerEvent = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        capture.setSuppressionEnabled(false)

        switch previous {
        case let .controlling(_, target, sessionID):
            if notifyPeer {
                try? await transport.send(ControlEnvelope(message: .releaseAll(sessionID)), to: target)
                try? await transport.send(ControlEnvelope(message: .deactivate(sessionID)), to: target)
            }
        case .receiving:
            for event in remoteInputState.releaseEvents() {
                injector.inject(event)
            }
            injector.releaseAll()
        case .idle:
            break
        }
    }

    private static func isEmergencyStop(_ event: InputEvent, flags: UInt64) -> Bool {
        guard case let .key(code, isDown, _) = event, isDown, code == emergencyKeyCode else { return false }
        return (flags & emergencyFlags) == emergencyFlags
    }

    private func schedulePointerFlush() {
        guard pointerFlushTask == nil else { return }
        pointerFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(8))
            await self?.flushPendingPointer()
        }
    }

    private func flushPendingPointer() async {
        pointerFlushTask?.cancel()
        pointerFlushTask = nil
        guard let event = pendingPointerEvent else { return }
        pendingPointerEvent = nil
        await sendInput(event)
    }

    private func startHeartbeat(target: DeviceID, sessionID: SessionID) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await self.sendHeartbeat(target: target, sessionID: sessionID)
            }
        }
    }

    private func sendHeartbeat(target: DeviceID, sessionID: SessionID) async {
        guard case let .controlling(_, expectedTarget, expectedSession) = state,
              target == expectedTarget, sessionID == expectedSession else { return }
        do {
            try await transport.send(
                ControlEnvelope(message: .heartbeat(sessionID: sessionID, timestampNanos: clock.nowNanoseconds())),
                to: target
            )
        } catch {
            await endCurrentSession(notifyPeer: false)
        }
    }

    private func startWatchdog(source: DeviceID, sessionID: SessionID) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
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
        return clock.nowNanoseconds() &- lastHeartbeatNanos > 3_000_000_000
    }
}
