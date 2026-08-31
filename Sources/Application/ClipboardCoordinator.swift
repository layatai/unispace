import Foundation
import UniSpaceDomain

/// Coordinates active-peer clipboard sharing without retaining clipboard history.
/// All mutable routing, ordering, and deduplication state is actor-isolated and
/// discarded when the workspace stops.
public actor ClipboardCoordinator {
    private let transport: any ClipboardTransport
    private let clipboard: any ClipboardService
    private let limits: ClipboardLimits
    private let connectionStream: AsyncStream<Set<DeviceID>>
    private let connectionContinuation: AsyncStream<Set<DeviceID>>.Continuation

    private var localDevice: DeviceDescriptor?
    private var workspace: WorkspaceSnapshot?
    private var connectedPeers = Set<DeviceID>()
    private var automaticDestination: DeviceID?
    private var engine: ClipboardSyncEngine?
    private var transportTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    private var pendingObservation: ClipboardObservation?
    private var sharingEnabled = false
    private var started = false

    public init(
        transport: any ClipboardTransport,
        clipboard: any ClipboardService,
        limits: ClipboardLimits = .default
    ) {
        self.transport = transport
        self.clipboard = clipboard
        self.limits = limits
        let pair = AsyncStream<Set<DeviceID>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        connectionStream = pair.stream
        connectionContinuation = pair.continuation
    }

    deinit {
        transportTask?.cancel()
        clipboardTask?.cancel()
        connectionContinuation.finish()
    }

    public func connectionEvents() -> AsyncStream<Set<DeviceID>> { connectionStream }

    public func start(
        localDevice: DeviceDescriptor,
        workspace: WorkspaceSnapshot,
        key: Data
    ) async throws {
        if started { await stop() }
        guard key.count >= 32,
              workspace.localDeviceID == localDevice.id,
              workspace.devices.contains(where: { $0.id == localDevice.id }) else {
            throw ClipboardProtocolError.workspaceMismatch
        }

        self.localDevice = localDevice
        self.workspace = workspace
        connectedPeers.removeAll()
        connectionContinuation.yield(connectedPeers)
        automaticDestination = nil
        pendingObservation = nil
        engine = ClipboardSyncEngine(localDeviceID: localDevice.id, limits: limits)
        started = true

        startTransportObservationIfNeeded()
        do {
            try await transport.start(localDevice: localDevice, workspace: workspace, key: key)
        } catch {
            started = false
            self.localDevice = nil
            self.workspace = nil
            engine = nil
            throw error
        }

        if sharingEnabled { await startClipboardObservation() }
    }

    public func stop() async {
        started = false
        await clipboard.stop()
        connectedPeers.removeAll()
        connectionContinuation.yield(connectedPeers)
        automaticDestination = nil
        pendingObservation = nil
        engine?.reset()
        engine = nil
        localDevice = nil
        workspace = nil
        transport.setDesiredPeer(nil)
        await transport.stop()
    }

    private func startTransportObservationIfNeeded() {
        guard transportTask == nil else { return }
        let transport = self.transport
        transportTask = Task { [weak self, transport] in
            for await event in transport.events() {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    public func setSharingEnabled(_ enabled: Bool) async {
        guard sharingEnabled != enabled else { return }
        sharingEnabled = enabled
        transport.setDesiredPeer(enabled ? automaticDestination : nil)
        if enabled, started {
            await startClipboardObservation()
        } else {
            await clipboard.stop()
            pendingObservation = nil
            if let localDevice {
                engine = ClipboardSyncEngine(localDeviceID: localDevice.id, limits: limits)
            }
        }
    }

    public func isSharingEnabled() -> Bool { sharingEnabled }

    public func setAutomaticDestination(_ deviceID: DeviceID?) async {
        guard deviceID != localDevice?.id else {
            guard automaticDestination != nil else { return }
            automaticDestination = nil
            transport.setDesiredPeer(nil)
            return
        }
        guard automaticDestination != deviceID else { return }
        automaticDestination = deviceID
        transport.setDesiredPeer(sharingEnabled ? deviceID : nil)
        await sendPendingObservationIfPossible()
    }

    public func connectedDeviceIDs() -> Set<DeviceID> { connectedPeers }

    public func automaticDestinationDeviceID() -> DeviceID? { automaticDestination }

    private func startClipboardObservation() async {
        let observations = await clipboard.events()
        guard clipboardTask == nil else { return }
        clipboardTask = Task { [weak self] in
            for await observation in observations {
                guard !Task.isCancelled else { return }
                await self?.handle(observation)
            }
        }
    }

    private func handle(_ observation: ClipboardObservation) async {
        guard started, sharingEnabled else { return }
        pendingObservation = observation
        await sendPendingObservationIfPossible()
    }

    private func sendPendingObservationIfPossible() async {
        guard let observation = pendingObservation,
              let localDevice,
              let workspace,
              let destination = automaticDestination,
              connectedPeers.contains(destination),
              let engine else { return }

        pendingObservation = nil
        do {
            var candidateEngine = engine
            guard let payload = try candidateEngine.makeLocalPayload(
                representations: observation.representations
            ) else {
                return
            }
            try await transport.send(
                ClipboardEnvelope(
                    workspaceID: workspace.id,
                    senderDeviceID: localDevice.id,
                    payload: payload
                ),
                to: destination
            )
            self.engine = candidateEngine
        } catch {
            // Clipboard contents and representation values are never logged.
            if pendingObservation == nil { pendingObservation = observation }
        }
    }

    private func handle(_ event: ClipboardTransportEvent) async {
        guard started else { return }
        switch event {
        case let .connected(deviceID):
            connectedPeers.insert(deviceID)
            connectionContinuation.yield(connectedPeers)
            await sendPendingObservationIfPossible()
        case let .disconnected(deviceID):
            connectedPeers.remove(deviceID)
            connectionContinuation.yield(connectedPeers)
        case let .failure(deviceID):
            if let deviceID, connectedPeers.remove(deviceID) != nil {
                connectionContinuation.yield(connectedPeers)
            }
        case let .update(deviceID, envelope):
            await receive(envelope, from: deviceID)
        }
    }

    private func receive(_ envelope: ClipboardEnvelope, from peer: DeviceID) async {
        guard sharingEnabled,
              connectedPeers.contains(peer),
              let workspace,
              var engine else { return }
        do {
            try envelope.validated(
                workspaceID: workspace.id,
                senderDeviceID: peer,
                limits: limits
            )
            let shouldApply = try engine.acceptRemote(
                envelope.payload,
                from: peer
            )
            self.engine = engine
            guard shouldApply else { return }
            // A validated clipboard update is stronger evidence of current
            // activity than a stale control-derived selection. Follow the most
            // recent authenticated sender in multi-peer workspaces.
            automaticDestination = peer
            transport.setDesiredPeer(peer)
            await clipboard.apply(envelope.payload)
        } catch {
            // Invalid or stale updates are ignored without exposing their contents.
        }
    }
}
