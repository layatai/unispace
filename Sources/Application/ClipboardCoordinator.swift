import Foundation
import UniSpaceDomain

/// Coordinates active-peer clipboard sharing without retaining clipboard history.
/// All mutable routing, ordering, and deduplication state is actor-isolated and
/// discarded when the workspace stops.
public actor ClipboardCoordinator {
    private let transport: any ClipboardTransport
    private let clipboard: any ClipboardService
    private let limits: ClipboardLimits

    private var localDevice: DeviceDescriptor?
    private var workspace: WorkspaceSnapshot?
    private var connectedPeers = Set<DeviceID>()
    private var automaticDestination: DeviceID?
    private var engine: ClipboardSyncEngine?
    private var transportTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
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
    }

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
        automaticDestination = nil
        engine = ClipboardSyncEngine(localDeviceID: localDevice.id, limits: limits)
        started = true

        do {
            try await transport.start(localDevice: localDevice, workspace: workspace, key: key)
        } catch {
            started = false
            self.localDevice = nil
            self.workspace = nil
            engine = nil
            throw error
        }

        let transport = self.transport
        transportTask = Task { [weak self, transport] in
            for await event in transport.events() {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
        if sharingEnabled { await startClipboardObservation() }
    }

    public func stop() async {
        started = false
        transportTask?.cancel()
        clipboardTask?.cancel()
        transportTask = nil
        clipboardTask = nil
        await clipboard.stop()
        connectedPeers.removeAll()
        automaticDestination = nil
        engine?.reset()
        engine = nil
        localDevice = nil
        workspace = nil
        await transport.stop()
    }

    public func setSharingEnabled(_ enabled: Bool) async {
        guard sharingEnabled != enabled else { return }
        sharingEnabled = enabled
        if enabled, started {
            await startClipboardObservation()
        } else {
            clipboardTask?.cancel()
            clipboardTask = nil
            await clipboard.stop()
            if let localDevice {
                engine = ClipboardSyncEngine(localDeviceID: localDevice.id, limits: limits)
            }
        }
    }

    public func isSharingEnabled() -> Bool { sharingEnabled }

    public func setAutomaticDestination(_ deviceID: DeviceID?) {
        guard deviceID != localDevice?.id else {
            automaticDestination = nil
            return
        }
        automaticDestination = deviceID
    }

    public func connectedDeviceIDs() -> Set<DeviceID> { connectedPeers }

    private func startClipboardObservation() async {
        guard clipboardTask == nil else { return }
        let observations = await clipboard.events()
        clipboardTask = Task { [weak self] in
            for await observation in observations {
                guard !Task.isCancelled else { return }
                await self?.handle(observation)
            }
        }
    }

    private func handle(_ observation: ClipboardObservation) async {
        guard sharingEnabled,
              let localDevice,
              let workspace,
              let destination = automaticDestination,
              connectedPeers.contains(destination),
              var engine else { return }

        do {
            guard let payload = try engine.makeLocalPayload(
                representations: observation.representations
            ) else {
                self.engine = engine
                return
            }
            self.engine = engine
            try await transport.send(
                ClipboardEnvelope(
                    workspaceID: workspace.id,
                    senderDeviceID: localDevice.id,
                    payload: payload
                ),
                to: destination
            )
        } catch {
            // Clipboard contents and representation values are never logged.
        }
    }

    private func handle(_ event: ClipboardTransportEvent) async {
        switch event {
        case let .connected(deviceID):
            connectedPeers.insert(deviceID)
        case let .disconnected(deviceID):
            connectedPeers.remove(deviceID)
        case let .failure(deviceID):
            if let deviceID { connectedPeers.remove(deviceID) }
        case let .update(deviceID, envelope):
            await receive(envelope, from: deviceID)
        }
    }

    private func receive(_ envelope: ClipboardEnvelope, from peer: DeviceID) async {
        guard sharingEnabled,
              connectedPeers.contains(peer),
              automaticDestination == peer,
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
            await clipboard.apply(envelope.payload)
        } catch {
            // Invalid or stale updates are ignored without exposing their contents.
        }
    }
}
