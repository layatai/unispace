import Foundation
import UniSpaceDomain

public protocol ClipboardContentReader: Sendable {
    func read(offset: UInt64, length: Int) async throws -> Data
    func digest() async throws -> Data
    func close() async
}
public protocol ClipboardSelectionSource: Sendable {
    /// Stats/metadata only: implementations must not hash or read contents.
    func describe(urls: [URL], epoch: UUID, generation: UInt64) async throws -> ClipboardStreamSelection
    func open(selectionID: UUID, file: ClipboardStreamFile) async throws -> any ClipboardContentReader
    func releaseSelection(_ selectionID: UUID) async
}

/// Owns the latest selection and peer-bound read leases. Announcements never
/// create content readers; replacing a selection preserves already opened ones.
public actor ClipboardStreamSource {
    private struct Lease {
        let value: ClipboardStreamLease
        let request: ClipboardStreamOpen
        let peer: DeviceID
        let reader: any ClipboardContentReader
        var deadline: UInt64
    }
    private struct OpenKey: Hashable {
        let peer: DeviceID
        let requestID: UUID
    }
    private struct PendingOpen {
        let token: UUID
        let request: ClipboardStreamOpen
        let task: Task<ClipboardStreamLease, Error>
    }
    private let source: any ClipboardSelectionSource
    private let clock: any MonotonicClock
    private let limits: ClipboardStreamLimits
    private var selection: ClipboardStreamSelection?
    private var destination: DeviceID?
    private var leases: [UUID: Lease] = [:]
    private var pendingOpens: [OpenKey: PendingOpen] = [:]
    private var expiryTask: Task<Void, Never>?
    private var epoch = UUID()
    private var generation: UInt64 = 0

    public init(source: any ClipboardSelectionSource, clock: any MonotonicClock, limits: ClipboardStreamLimits = .default) {
        self.source = source; self.clock = clock; self.limits = limits
    }
    public func replace(urls: [URL], destination: DeviceID?) async throws -> ClipboardStreamSelection? {
        generation &+= 1
        let expectedGeneration = generation
        let previous = selection
        selection = nil
        self.destination = destination
        if let previous { await source.releaseSelection(previous.id) }
        guard !urls.isEmpty else { return nil }
        let described = try await source.describe(urls: urls, epoch: epoch, generation: expectedGeneration)
        try described.validate(limits: limits)
        guard generation == expectedGeneration else {
            await source.releaseSelection(described.id)
            throw ClipboardStreamFailure.cancelled
        }
        selection = described
        return described
    }
    public func current() -> ClipboardStreamSelection? { selection }
    public func setDestination(_ peer: DeviceID?) { destination = peer }
    public func open(_ request: ClipboardStreamOpen, peer: DeviceID) async throws -> ClipboardStreamLease {
        await expire()
        guard destination == peer, let selection, selection.id == request.selectionID,
              let file = selection.files.first(where: { $0.id == request.fileID }) else { throw ClipboardStreamFailure.unavailable }
        guard file.version == request.version else { throw ClipboardStreamFailure.changed }
        let key = OpenKey(peer: peer, requestID: request.requestID)
        if let existing = leases.values.first(where: { $0.peer == peer && $0.request.requestID == request.requestID }) {
            guard existing.request == request else { throw ClipboardStreamFailure.invalidRequest }
            return existing.value
        }
        if let pending = pendingOpens[key] {
            guard pending.request == request else { throw ClipboardStreamFailure.invalidRequest }
            return try await pending.task.value
        }
        guard leases.count + pendingOpens.count < limits.maximumLeases else { throw ClipboardStreamFailure.busy }
        let token = UUID()
        let task = Task { try await self.createLease(request, selection: selection, file: file, peer: peer) }
        pendingOpens[key] = PendingOpen(token: token, request: request, task: task)
        defer { if pendingOpens[key]?.token == token { pendingOpens.removeValue(forKey: key) } }
        return try await task.value
    }
    private func createLease(_ request: ClipboardStreamOpen, selection: ClipboardStreamSelection,
                             file: ClipboardStreamFile, peer: DeviceID) async throws -> ClipboardStreamLease {
        let reader = try await source.open(selectionID: selection.id, file: file)
        guard !Task.isCancelled, self.selection?.id == selection.id, destination == peer else {
            await reader.close()
            throw ClipboardStreamFailure.cancelled
        }
        let value = ClipboardStreamLease(requestID: request.requestID, selectionID: selection.id, fileID: file.id,
            size: file.size, maximumReadBytes: UInt32(limits.maximumReadBytes))
        leases[value.leaseID] = Lease(value: value, request: request, peer: peer, reader: reader, deadline: deadline())
        startExpirySweep()
        return value
    }
    public func read(_ request: ClipboardStreamRead, peer: DeviceID) async throws -> ClipboardStreamRange {
        await expire()
        guard var lease = leases[request.leaseID], lease.peer == peer,
              lease.value.fileID == request.fileID else { throw ClipboardStreamFailure.expired }
        guard request.length > 0, Int(request.length) <= limits.maximumReadBytes,
              request.offset <= lease.value.size else { throw ClipboardStreamFailure.invalidRequest }
        let (end, overflow) = request.offset.addingReportingOverflow(UInt64(request.length))
        guard !overflow else { throw ClipboardStreamFailure.invalidRequest }
        let length = Int(min(end, lease.value.size) - request.offset)
        lease.deadline = deadline(); leases[request.leaseID] = lease
        let bytes = try await lease.reader.read(offset: request.offset, length: length)
        guard leases[request.leaseID] != nil else { throw ClipboardStreamFailure.cancelled }
        guard bytes.count == length else { throw ClipboardStreamFailure.changed }
        return .init(requestID: request.requestID, leaseID: request.leaseID, fileID: request.fileID, offset: request.offset, data: bytes)
    }
    public func finish(_ request: ClipboardStreamFinish, peer: DeviceID) async throws -> ClipboardStreamFinish {
        await expire()
        guard let lease = leases[request.leaseID], lease.peer == peer else { throw ClipboardStreamFailure.expired }
        guard request.digest.count == 32 else { throw ClipboardStreamFailure.invalidRequest }
        let digest = try await lease.reader.digest()
        guard leases[request.leaseID] != nil else { throw ClipboardStreamFailure.cancelled }
        guard digest == request.digest else { throw ClipboardStreamFailure.integrityFailure }
        await close(request.leaseID, peer: peer)
        return .init(requestID: request.requestID, leaseID: request.leaseID, digest: digest)
    }
    public func close(_ id: UUID, peer: DeviceID) async {
        guard let lease = leases[id], lease.peer == peer else { return }
        leases.removeValue(forKey: id)
        await lease.reader.close()
    }
    public func disconnect(_ peer: DeviceID) async {
        for (key, pending) in pendingOpens where key.peer == peer {
            pending.task.cancel(); pendingOpens.removeValue(forKey: key)
        }
        let matching = leases.values.filter { $0.peer == peer }
        for lease in matching { leases.removeValue(forKey: lease.value.leaseID) }
        if destination == peer { destination = nil }
        for lease in matching { await lease.reader.close() }
    }
    public func stop() async {
        expiryTask?.cancel(); expiryTask = nil
        for pending in pendingOpens.values { pending.task.cancel() }
        pendingOpens.removeAll()
        generation &+= 1
        epoch = UUID()
        let previous = selection; selection = nil; destination = nil
        let active = Array(leases.values); leases.removeAll()
        for lease in active { await lease.reader.close() }
        if let previous { await source.releaseSelection(previous.id) }
    }
    public func expire() async {
        let now = clock.nowNanoseconds()
        let expired = leases.values.filter { $0.deadline <= now }
        for lease in expired { leases.removeValue(forKey: lease.value.leaseID) }
        for lease in expired { await lease.reader.close() }
    }
    private func startExpirySweep() {
        guard expiryTask == nil else { return }
        let interval = Duration.nanoseconds(Int64(max(1_000_000, min(limits.leaseLifetimeNanoseconds / 2, 1_000_000_000))))
        let clock = self.clock
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                guard self != nil else { return }
                await self?.expire()
            }
        }
    }
    private func deadline() -> UInt64 {
        let (value, overflow) = clock.nowNanoseconds().addingReportingOverflow(limits.leaseLifetimeNanoseconds)
        return overflow ? UInt64.max : value
    }
}
