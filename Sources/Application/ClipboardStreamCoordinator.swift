import Foundation
import CryptoKit
import UniSpaceDomain

public protocol ClipboardVirtualFileAdapter: Sendable {
    func publish(_ selection: ClipboardStreamSelection, from peer: DeviceID) async throws
    func withdraw(_ selectionID: UUID, from peer: DeviceID) async
    func stop() async
}

/// Routes the negotiated v2 stream messages on the existing encrypted content
/// transport. Native adapters consume RemoteClipboardReader; no paste-key hook.
public actor ClipboardStreamCoordinator {
    private struct Pending {
        let peer: DeviceID
        let continuation: AsyncThrowingStream<ClipboardStreamMessage, Error>.Continuation
        let timeout: Task<Void, Never>
    }
    private let transport: any FileTransferTransport
    private let source: ClipboardStreamSource
    private let adapter: any ClipboardVirtualFileAdapter
    private var workspace: WorkspaceSnapshot?
    private var localDevice: DeviceDescriptor?
    private var connected = Set<DeviceID>()
    private var destination: DeviceID?
    private var remote: [DeviceID: ClipboardStreamSelection] = [:]
    private var pending: [UUID: Pending] = [:]
    private var advertised: [DeviceID: ClipboardStreamSelection] = [:]
    private var epoch = UUID()

    public init(transport: any FileTransferTransport, source: ClipboardStreamSource, adapter: any ClipboardVirtualFileAdapter) {
        self.transport = transport; self.source = source; self.adapter = adapter
    }
    public func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot) async {
        await stop()
        self.localDevice = localDevice; self.workspace = workspace
    }
    public func stop() async {
        workspace = nil; localDevice = nil; destination = nil; advertised.removeAll()
        connected.removeAll(); remote.removeAll(); epoch = UUID()
        let requests = pending.values; pending.removeAll()
        for request in requests { request.timeout.cancel(); request.continuation.finish(throwing: ClipboardStreamFailure.cancelled) }
        await adapter.stop(); await source.stop()
    }
    public func setDestination(_ peer: DeviceID?) async {
        if let old = destination, old != peer, let selection = advertised.removeValue(forKey: old) {
            try? await send(.withdraw(.init(selection.id)), to: old)
        }
        destination = peer
        await syncServedPeers()
        await advertiseIfPossible()
    }
    public func connection(_ peer: DeviceID, active: Bool) async {
        if active { connected.insert(peer); await syncServedPeers(); await advertiseIfPossible(); return }
        connected.remove(peer)
        if let selection = remote.removeValue(forKey: peer) { await adapter.withdraw(selection.id, from: peer) }
        if let selection = advertised.removeValue(forKey: peer) {
            try? await send(.withdraw(.init(selection.id)), to: peer)
        }
        await syncServedPeers()
        let matching = pending.filter { $0.value.peer == peer }
        for (id, request) in matching {
            pending.removeValue(forKey: id); request.timeout.cancel()
            request.continuation.finish(throwing: ClipboardStreamFailure.unavailable)
        }
        await source.disconnect(peer)
    }
    public func copied(_ urls: [URL]) async throws {
        for (peer, selection) in advertised {
            try? await send(.withdraw(.init(selection.id)), to: peer)
        }
        advertised.removeAll()
        _ = try await source.replace(urls: urls, destination: nil)
        await syncServedPeers()
        await advertiseIfPossible()
    }
    public func selection(from peer: DeviceID) -> ClipboardStreamSelection? { remote[peer] }
    private func compatible(_ peer: DeviceID) -> Bool {
        workspace?.devices.first(where: { $0.id == peer })?.capabilities.contains(.fileClipboardStreamV2) == true
    }
    private func advertiseIfPossible() async {
        guard destination != nil, let selection = await source.current() else { return }
        for peer in connected where compatible(peer) {
            guard advertised[peer]?.id != selection.id else { continue }
            do {
                try await send(.announce(selection), to: peer)
                advertised[peer] = selection
            } catch { /* Retry on the next trigger; served peers are not opened by announce failures. */ }
        }
        await syncServedPeers()
    }
    private func syncServedPeers() async {
        var peers = Set(advertised.keys)
        if let destination { peers.insert(destination) }
        await source.setServedPeers(peers)
    }
    public func receive(_ message: ClipboardStreamMessage, from peer: DeviceID) async {
        guard workspace != nil, connected.contains(peer), compatible(peer) else { return }
        switch message {
        case let .announce(selection):
            do {
                try selection.validate()
                if let previous = remote[peer], previous.epoch == selection.epoch, previous.generation >= selection.generation { return }
                let expectedEpoch = epoch
                try await adapter.publish(selection, from: peer)
                guard epoch == expectedEpoch, connected.contains(peer) else { await adapter.withdraw(selection.id, from: peer); return }
                remote[peer] = selection
            } catch { /* Native availability is surfaced by the adapter. No eager fallback. */ }
        case let .withdraw(reference):
            if let previous = remote[peer], previous.id == reference.id {
                remote.removeValue(forKey: peer); await adapter.withdraw(previous.id, from: peer)
            }
        case let .open(request):
            do { try await send(.opened(try await source.open(request, peer: peer)), to: peer) }
            catch { try? await send(.error(.init(requestID: request.requestID, failure: failure(error))), to: peer) }
        case let .read(request):
            do { try await send(.range(try await source.read(request, peer: peer)), to: peer) }
            catch { try? await send(.error(.init(requestID: request.requestID, failure: failure(error))), to: peer) }
        case let .finish(request):
            do { try await send(.finished(try await source.finish(request, peer: peer)), to: peer) }
            catch { try? await send(.error(.init(requestID: request.requestID, failure: failure(error))), to: peer) }
        case let .close(reference): await source.close(reference.id, peer: peer)
        case .opened, .range, .finished, .error:
            guard let id = responseID(message), let request = pending[id], request.peer == peer else { return }
            pending.removeValue(forKey: id); request.timeout.cancel()
            if case let .error(value) = message { request.continuation.finish(throwing: value.failure) }
            else { request.continuation.yield(message); request.continuation.finish() }
        }
    }
    public func open(selection: ClipboardStreamSelection, file: ClipboardStreamFile, peer: DeviceID) async throws -> ClipboardStreamLease {
        guard remote[peer]?.id == selection.id else { throw ClipboardStreamFailure.expired }
        let request = ClipboardStreamOpen(selectionID: selection.id, fileID: file.id, version: file.version)
        guard case let .opened(value) = try await exchange(.open(request), requestID: request.requestID, peer: peer),
              value.requestID == request.requestID, value.selectionID == selection.id, value.fileID == file.id,
              value.size == file.size, value.maximumReadBytes > 0, value.maximumReadBytes <= ClipboardStreamLimits.default.maximumReadBytes else {
            throw ClipboardStreamFailure.invalidRequest
        }
        return value
    }
    public func read(lease: ClipboardStreamLease, offset: UInt64, length: Int, peer: DeviceID) async throws -> Data {
        guard length > 0, length <= lease.maximumReadBytes, offset <= lease.size else { throw ClipboardStreamFailure.invalidRequest }
        let request = ClipboardStreamRead(leaseID: lease.leaseID, fileID: lease.fileID, offset: offset, length: UInt32(length))
        guard case let .range(value) = try await exchange(.read(request), requestID: request.requestID, peer: peer),
              value.requestID == request.requestID, value.leaseID == lease.leaseID, value.fileID == lease.fileID,
              value.offset == offset, UInt64(value.data.count) <= min(UInt64(length), lease.size - offset),
              !value.data.isEmpty || offset == lease.size else { throw ClipboardStreamFailure.invalidRequest }
        return value.data
    }
    public func finish(lease: ClipboardStreamLease, digest: Data, peer: DeviceID) async throws {
        let request = ClipboardStreamFinish(leaseID: lease.leaseID, digest: digest)
        guard case let .finished(value) = try await exchange(.finish(request), requestID: request.requestID, peer: peer),
              value.leaseID == lease.leaseID, value.digest == digest else { throw ClipboardStreamFailure.integrityFailure }
    }
    public func download(fileID: UUID, selectionID: UUID, peer: DeviceID, to destination: URL,
                         progress: @Sendable (UInt64, UInt64) async -> Void = { _, _ in }) async throws {
        guard let selection = remote[peer], selection.id == selectionID,
              let file = selection.files.first(where: { $0.id == fileID }) else { throw ClipboardStreamFailure.expired }
        let lease = try await open(selection: selection, file: file, peer: peer)
        do {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ClipboardStreamFailure.ioFailure
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var offset: UInt64 = 0
            var hasher = SHA256()
            await progress(0, file.size)
            while offset < file.size {
                try Task.checkCancellation()
                let count = Int(min(UInt64(lease.maximumReadBytes), file.size - offset))
                let bytes = try await readWithRetry(lease: lease, offset: offset, length: count, peer: peer)
                guard !bytes.isEmpty else { throw ClipboardStreamFailure.changed }
                try output.write(contentsOf: bytes); hasher.update(data: bytes)
                offset += UInt64(bytes.count)
                await progress(offset, file.size)
            }
            try output.synchronize()
            try await finish(lease: lease, digest: Data(hasher.finalize()), peer: peer)
        } catch {
            await close(lease: lease, peer: peer)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    public func close(lease: ClipboardStreamLease, peer: DeviceID) async { try? await send(.close(.init(lease.leaseID)), to: peer) }
    // Retry only transport-level loss: lease-bound failures must surface unchanged.
    private func readWithRetry(lease: ClipboardStreamLease, offset: UInt64, length: Int, peer: DeviceID) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await read(lease: lease, offset: offset, length: length, peer: peer)
            } catch let failure as ClipboardStreamFailure
            where attempt < 2 && (failure == .ioFailure || failure == .unavailable) {
                attempt += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    private func exchange(_ message: ClipboardStreamMessage, requestID: UUID, peer: DeviceID) async throws -> ClipboardStreamMessage {
        guard connected.contains(peer), compatible(peer), pending.count < 32 else { throw ClipboardStreamFailure.unavailable }
        let pair = AsyncThrowingStream<ClipboardStreamMessage, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)); await self?.expireRequest(requestID) } catch {}
        }
        pending[requestID] = Pending(peer: peer, continuation: pair.continuation, timeout: deadline)
        defer { pending.removeValue(forKey: requestID); deadline.cancel() }
        try await send(message, to: peer)
        for try await response in pair.stream { return response }
        try Task.checkCancellation()
        throw ClipboardStreamFailure.cancelled
    }
    private func expireRequest(_ id: UUID) {
        pending.removeValue(forKey: id)?.continuation.finish(throwing: ClipboardStreamFailure.expired)
    }
    private func send(_ message: ClipboardStreamMessage, to peer: DeviceID) async throws {
        guard let workspace, let localDevice, connected.contains(peer), compatible(peer) else { throw ClipboardStreamFailure.unavailable }
        try await transport.send(.init(workspaceID: workspace.id, senderDeviceID: localDevice.id, message: .clipboardStream(message)), to: peer)
    }
    private func responseID(_ value: ClipboardStreamMessage) -> UUID? {
        switch value {
        case let .opened(value): value.requestID
        case let .range(value): value.requestID
        case let .finished(value): value.requestID
        case let .error(value): value.requestID
        default: nil
        }
    }
    private func failure(_ error: Error) -> ClipboardStreamFailure { error as? ClipboardStreamFailure ?? .ioFailure }
}
