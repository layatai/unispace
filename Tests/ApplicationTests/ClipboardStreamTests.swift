import CryptoKit
import Foundation
import Testing
@testable import UniSpaceApplication
import UniSpaceDomain

struct ClipboardStreamTests {
    @Test func idleLeaseExpiresWithoutAnotherContentRequest() async throws {
        let source = StreamSourceSpy()
        let clock = StreamTestClock()
        let service = ClipboardStreamSource(source: source, clock: clock,
            limits: .init(leaseLifetimeNanoseconds: 20_000_000))
        let peer = DeviceID()
        let selection = try #require(try await service.replace(urls: [URL(fileURLWithPath: "/fixture/a")], destination: peer))
        _ = try await service.open(.init(selectionID: selection.id, fileID: selection.files[0].id, version: "version"), peer: peer)
        clock.advance(20_000_001)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await source.reader.closed), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await source.reader.closed)
        await service.stop()
    }
    @Test func duplicateOpenRequestsShareOneReaderAndEnforceTheLeaseLimit() async throws {
        let source = StreamSourceSpy()
        let service = ClipboardStreamSource(source: source, clock: StreamTestClock(), limits: .init(maximumLeases: 1))
        let peer = DeviceID()
        let selection = try #require(try await service.replace(urls: [URL(fileURLWithPath: "/fixture/a")], destination: peer))
        let request = ClipboardStreamOpen(selectionID: selection.id, fileID: selection.files[0].id, version: "version")
        async let first = service.open(request, peer: peer)
        async let second = service.open(request, peer: peer)
        let values = try await [first, second]
        #expect(values[0] == values[1])
        #expect(await source.openCount == 1)
        #expect(try await service.open(request, peer: peer) == values[0])
        await #expect(throws: ClipboardStreamFailure.busy) {
            try await service.open(.init(selectionID: selection.id, fileID: selection.files[0].id, version: "version"), peer: peer)
        }
        await service.stop()
        #expect(await source.reader.closed)
    }
    @Test func metadataAndAnnouncementsNeverReadOrHashContent() async throws {
        let source = StreamSourceSpy()
        let service = ClipboardStreamSource(source: source, clock: StreamTestClock())
        let peer = DeviceID()
        let selection = try #require(try await service.replace(urls: [URL(fileURLWithPath: "/fixture/a.bin")], destination: peer))
        #expect(await service.current() == selection)
        await service.setDestination(peer)
        #expect(await source.openCount == 0)
        #expect(await source.reader.readCount == 0)
        #expect(await source.reader.digestCount == 0)
        await service.stop()
    }
    @Test func replacementPreservesPinnedReadsButRejectsOldUnpinnedOpens() async throws {
        let source = StreamSourceSpy()
        let service = ClipboardStreamSource(source: source, clock: StreamTestClock())
        let peer = DeviceID()
        let first = try #require(try await service.replace(urls: [URL(fileURLWithPath: "/fixture/first")], destination: peer))
        let request = ClipboardStreamOpen(selectionID: first.id, fileID: first.files[0].id, version: first.files[0].version)
        let lease = try await service.open(request, peer: peer)
        let second = try #require(try await service.replace(urls: [URL(fileURLWithPath: "/fixture/second")], destination: peer))
        #expect(first.id != second.id)
        await #expect(throws: ClipboardStreamFailure.unavailable) { try await service.open(request, peer: peer) }
        let response = try await service.read(.init(leaseID: lease.leaseID, fileID: lease.fileID, offset: 1, length: 3), peer: peer)
        #expect(response.data == Data("bcd".utf8))
        #expect(await source.reader.closed == false)
        await service.stop()
    }
    @Test func rangeIdentityAndPeerBindingAreStrict() async throws {
        let source = StreamSourceSpy()
        let service = ClipboardStreamSource(source: source, clock: StreamTestClock())
        let peer = DeviceID()
        let selection = try #require(try await service.replace(urls: [URL(fileURLWithPath: "/fixture/a")], destination: peer))
        let open = ClipboardStreamOpen(selectionID: selection.id, fileID: selection.files[0].id, version: "version")
        await #expect(throws: ClipboardStreamFailure.unavailable) { try await service.open(open, peer: DeviceID()) }
        let lease = try await service.open(open, peer: peer)
        let request = ClipboardStreamRead(leaseID: lease.leaseID, fileID: lease.fileID, offset: 0, length: 2)
        await #expect(throws: ClipboardStreamFailure.expired) { try await service.read(request, peer: DeviceID()) }
        let response = try await service.read(request, peer: peer)
        #expect(response.requestID == request.requestID)
        #expect(response.leaseID == request.leaseID)
        #expect(response.offset == 0)
        #expect(response.data == Data("ab".utf8))
        await service.close(lease.leaseID, peer: DeviceID())
        #expect(await source.reader.closed == false)
        await service.close(lease.leaseID, peer: peer)
        #expect(await source.reader.closed == true)
    }
    @Test(arguments: [UInt64.max, 7])
    func invalidOffsetsNeverReachTheContentReader(offset: UInt64) async throws {
        let source = StreamSourceSpy()
        let service = ClipboardStreamSource(source: source, clock: StreamTestClock())
        let peer = DeviceID()
        let selection = try #require(try await service.replace(urls: [URL(fileURLWithPath: "/fixture/a")], destination: peer))
        let lease = try await service.open(.init(selectionID: selection.id, fileID: selection.files[0].id, version: "version"), peer: peer)
        await #expect(throws: ClipboardStreamFailure.invalidRequest) {
            try await service.read(.init(leaseID: lease.leaseID, fileID: lease.fileID, offset: offset, length: 2), peer: peer)
        }
        #expect(await source.reader.readCount == 0)
        await service.stop()
    }
    @Test func boundedReadsEOFAndFinalIntegrity() async throws {
        let source = StreamSourceSpy()
        let service = ClipboardStreamSource(source: source, clock: StreamTestClock())
        let peer = DeviceID()
        let selection = try #require(try await service.replace(urls: [URL(fileURLWithPath: "/fixture/a")], destination: peer))
        let lease = try await service.open(.init(selectionID: selection.id, fileID: selection.files[0].id, version: "version"), peer: peer)
        await #expect(throws: ClipboardStreamFailure.invalidRequest) {
            try await service.read(.init(leaseID: lease.leaseID, fileID: lease.fileID, offset: 0, length: 262_145), peer: peer)
        }
        let last = try await service.read(.init(leaseID: lease.leaseID, fileID: lease.fileID, offset: 4, length: 10), peer: peer)
        #expect(last.data == Data("ef".utf8))
        let eof = try await service.read(.init(leaseID: lease.leaseID, fileID: lease.fileID, offset: 6, length: 1), peer: peer)
        #expect(eof.data.isEmpty)
        await #expect(throws: ClipboardStreamFailure.integrityFailure) {
            try await service.finish(.init(leaseID: lease.leaseID, digest: Data(repeating: 0, count: 32)), peer: peer)
        }
        let finish = try await service.finish(.init(leaseID: lease.leaseID, digest: Data(SHA256.hash(data: Data("abcdef".utf8)))), peer: peer)
        #expect(finish.digest.count == 32)
        #expect(await source.reader.closed)
    }
    @Test func expiryAndDisconnectReleaseReadersWithoutResurrectingSelections() async throws {
        let source = StreamSourceSpy()
        let clock = StreamTestClock()
        let service = ClipboardStreamSource(source: source, clock: clock, limits: .init(leaseLifetimeNanoseconds: 10))
        let peer = DeviceID()
        let selection = try #require(try await service.replace(urls: [URL(fileURLWithPath: "/fixture/a")], destination: peer))
        let lease = try await service.open(.init(selectionID: selection.id, fileID: selection.files[0].id, version: "version"), peer: peer)
        clock.advance(11)
        await service.expire()
        #expect(await source.reader.closed)
        await #expect(throws: ClipboardStreamFailure.expired) {
            try await service.read(.init(leaseID: lease.leaseID, fileID: lease.fileID, offset: 0, length: 1), peer: peer)
        }
        await service.disconnect(peer)
        await #expect(throws: ClipboardStreamFailure.unavailable) {
            try await service.open(.init(selectionID: selection.id, fileID: selection.files[0].id, version: "version"), peer: peer)
        }
        await service.stop()
        #expect(await service.current() == nil)
    }
    @Test func codecKeepsLargeOffsetsAndBinaryRangeBytesPortable() throws {
        let range = ClipboardStreamRange(requestID: UUID(), leaseID: UUID(), fileID: UUID(), offset: (1 << 32) + 5,
                                        data: Data([0, 255, 1]))
        let encoded = try ClipboardStreamCodec.encode(.range(range))
        #expect(encoded.count == 3 + 48 + 8 + 4 + 3)
        #expect(try ClipboardStreamCodec.decode(encoded) == .range(range))
        for count in 0..<encoded.count {
            #expect(throws: ClipboardStreamFailure.invalidRequest) { try ClipboardStreamCodec.decode(Data(encoded.prefix(count))) }
        }
        var wrongVersion = encoded; wrongVersion[1] = 1
        #expect(throws: ClipboardStreamFailure.invalidRequest) { try ClipboardStreamCodec.decode(wrongVersion) }
        #expect(try ClipboardStreamCodec.decode((Data([99]) + encoded).dropFirst()) == .range(range))
    }
}

private actor StreamSourceSpy: ClipboardSelectionSource {
    let reader = StreamReaderSpy()
    var openCount = 0
    func describe(urls: [URL], epoch: UUID, generation: UInt64) -> ClipboardStreamSelection {
        .init(epoch: epoch, generation: generation, files: [.init(name: "fixture.bin", size: 6, version: "version")])
    }
    func open(selectionID: UUID, file: ClipboardStreamFile) -> any ClipboardContentReader { openCount += 1; return reader }
    func releaseSelection(_ selectionID: UUID) {}
}
private actor StreamReaderSpy: ClipboardContentReader {
    var readCount = 0
    var digestCount = 0
    var closed = false
    func read(offset: UInt64, length: Int) -> Data { readCount += 1; return Data("abcdef".utf8).subdata(in: Int(offset)..<(Int(offset) + length)) }
    func digest() -> Data { digestCount += 1; return Data(SHA256.hash(data: Data("abcdef".utf8))) }
    func close() { closed = true }
}
private final class StreamTestClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0
    func nowNanoseconds() -> UInt64 { lock.withLock { now } }
    func advance(_ value: UInt64) { lock.withLock { now += value } }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

struct ClipboardStreamCoordinatorTests {
    @Test func copyIsMetadataOnlyAndDemandDownloadsVerifiedContent() async throws {
        let fixture = StreamPairFixture()
        await fixture.start()
        try await fixture.sender.copied([URL(fileURLWithPath: "/fixture/a")])
        let selection = try #require(await fixture.receiver.selection(from: fixture.local.id))
        #expect(await fixture.source.openCount == 0)
        #expect(await fixture.source.reader.readCount == 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("fixture.bin")
        try await fixture.receiver.download(fileID: selection.files[0].id, selectionID: selection.id,
                                            peer: fixture.local.id, to: output)
        #expect(try Data(contentsOf: output) == Data("abcdef".utf8))
        #expect(await fixture.source.openCount == 1)
        #expect(await fixture.source.reader.digestCount == 1)
        #expect(await fixture.source.reader.closed)
        await fixture.stop()
    }
    @Test func disconnectWithdrawsRemoteOwnershipAndReconnectAdvertisesWithoutReading() async throws {
        let fixture = StreamPairFixture()
        await fixture.start()
        try await fixture.sender.copied([URL(fileURLWithPath: "/fixture/a")])
        let selection = try #require(await fixture.receiver.selection(from: fixture.local.id))
        await fixture.receiver.connection(fixture.local.id, active: false)
        #expect(await fixture.receiver.selection(from: fixture.local.id) == nil)
        #expect(await fixture.receiverAdapter.withdrawn == [selection.id])
        await fixture.sender.connection(fixture.remote.id, active: false)
        await fixture.receiver.connection(fixture.local.id, active: true)
        await fixture.sender.connection(fixture.remote.id, active: true)
        #expect(await fixture.receiver.selection(from: fixture.local.id) == selection)
        #expect(await fixture.source.openCount == 0)
        try await fixture.sender.copied([])
        #expect(await fixture.receiver.selection(from: fixture.local.id) == nil)
        await fixture.stop()
    }
    @Test func destinationChangeWithdrawsAndRejectsNewOpens() async throws {
        let fixture = StreamPairFixture()
        await fixture.start()
        try await fixture.sender.copied([URL(fileURLWithPath: "/fixture/a")])
        let selection = try #require(await fixture.receiver.selection(from: fixture.local.id))
        await fixture.sender.setDestination(nil)
        #expect(await fixture.receiver.selection(from: fixture.local.id) == nil)
        await #expect(throws: ClipboardStreamFailure.expired) {
            try await fixture.receiver.open(selection: selection, file: selection.files[0], peer: fixture.local.id)
        }
        #expect(await fixture.source.openCount == 0)
        await fixture.stop()
    }
    @Test func corruptedRangesRejectTheDownloadAndRemoveItsPartialFile() async throws {
        let fixture = StreamPairFixture()
        await fixture.start()
        try await fixture.sender.copied([URL(fileURLWithPath: "/fixture/a")])
        let selection = try #require(await fixture.receiver.selection(from: fixture.local.id))
        fixture.senderTransport.corruptRanges()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: ClipboardStreamFailure.invalidRequest) {
            try await fixture.receiver.download(fileID: selection.files[0].id, selectionID: selection.id,
                                                peer: fixture.local.id, to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(await fixture.source.reader.closed)
        await fixture.stop()
    }
    @Test func sourceErrorsPropagateWithRequestIdentity() async throws {
        let fixture = StreamPairFixture()
        await fixture.start()
        try await fixture.sender.copied([URL(fileURLWithPath: "/fixture/a")])
        let selection = try #require(await fixture.receiver.selection(from: fixture.local.id))
        let lease = try await fixture.receiver.open(selection: selection, file: selection.files[0], peer: fixture.local.id)
        await #expect(throws: ClipboardStreamFailure.invalidRequest) {
            try await fixture.receiver.read(lease: lease, offset: 7, length: 1, peer: fixture.local.id)
        }
        await #expect(throws: ClipboardStreamFailure.integrityFailure) {
            try await fixture.receiver.finish(lease: lease, digest: Data(repeating: 0, count: 32), peer: fixture.local.id)
        }
        await fixture.receiver.close(lease: lease, peer: fixture.local.id)
        #expect(await fixture.source.reader.closed)
        await fixture.stop()
    }
    @Test func staleGenerationsAndUntrustedPeersCannotReplaceTheClipboard() async throws {
        let fixture = StreamPairFixture()
        await fixture.start()
        try await fixture.sender.copied([URL(fileURLWithPath: "/fixture/a")])
        let selection = try #require(await fixture.receiver.selection(from: fixture.local.id))
        await fixture.receiver.receive(.announce(selection), from: fixture.local.id)
        await fixture.receiver.receive(.announce(selection), from: DeviceID())
        await fixture.receiver.receive(.withdraw(.init(UUID())), from: fixture.local.id)
        #expect(await fixture.receiverAdapter.published.count == 1)
        #expect(await fixture.receiver.selection(from: fixture.local.id) == selection)
        await fixture.stop()
        await fixture.receiver.receive(.announce(selection), from: fixture.local.id)
        #expect(await fixture.receiver.selection(from: fixture.local.id) == nil)
    }
    @Test func unsupportedPeerNeverGetsAContentOffer() async throws {
        let fixture = StreamPairFixture(compatible: false)
        await fixture.start()
        try await fixture.sender.copied([URL(fileURLWithPath: "/fixture/a")])
        #expect(await fixture.receiver.selection(from: fixture.local.id) == nil)
        #expect(await fixture.source.openCount == 0)
        #expect(fixture.senderTransport.sentCount() == 0)
        await fixture.stop()
    }
}

private final class StreamPairFixture: Sendable {
    let local: DeviceDescriptor
    let remote: DeviceDescriptor
    let workspace: WorkspaceSnapshot
    let senderTransport = StreamLoopbackTransport()
    let receiverTransport = StreamLoopbackTransport()
    let source = StreamSourceSpy()
    let receiverAdapter = StreamAdapterSpy()
    let sender: ClipboardStreamCoordinator
    let receiver: ClipboardStreamCoordinator
    init(compatible: Bool = true) {
        let capabilities: Set<DeviceCapability> = compatible ? [.fileTransferV1, .fileClipboardStreamV2] : [.fileTransferV1]
        local = DeviceDescriptor(id: DeviceID(), name: "Source", capabilities: capabilities)
        remote = DeviceDescriptor(id: DeviceID(), name: "Destination", capabilities: capabilities)
        workspace = WorkspaceSnapshot(id: WorkspaceID(), name: "Clipboard QA", localDeviceID: local.id, devices: [local, remote])
        sender = ClipboardStreamCoordinator(transport: senderTransport,
            source: ClipboardStreamSource(source: source, clock: StreamTestClock()), adapter: StreamAdapterSpy())
        receiver = ClipboardStreamCoordinator(transport: receiverTransport,
            source: ClipboardStreamSource(source: StreamSourceSpy(), clock: StreamTestClock()), adapter: receiverAdapter)
        senderTransport.connect(to: receiver)
        receiverTransport.connect(to: sender)
    }
    func start() async {
        await sender.start(localDevice: local, workspace: workspace)
        await receiver.start(localDevice: remote, workspace: workspace)
        await sender.connection(remote.id, active: true)
        await receiver.connection(local.id, active: true)
        await sender.setDestination(remote.id)
    }
    func stop() async { await sender.stop(); await receiver.stop() }
}
private actor StreamAdapterSpy: ClipboardVirtualFileAdapter {
    var published: [ClipboardStreamSelection] = []
    var withdrawn: [UUID] = []
    func publish(_ selection: ClipboardStreamSelection, from peer: DeviceID) { published.append(selection) }
    func withdraw(_ selectionID: UUID, from peer: DeviceID) { withdrawn.append(selectionID) }
    func stop() {}
}
private final class StreamLoopbackTransport: FileTransferTransport, @unchecked Sendable {
    private let lock = NSLock()
    private weak var destination: ClipboardStreamCoordinator?
    private var corrupt = false
    private var count = 0
    func connect(to coordinator: ClipboardStreamCoordinator) { lock.withLock { destination = coordinator } }
    func corruptRanges() { lock.withLock { corrupt = true } }
    func sentCount() -> Int { lock.withLock { count } }
    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func events() -> AsyncStream<FileTransferTransportEvent> { AsyncStream { $0.finish() } }
    func send(_ envelope: FileTransferEnvelope, to deviceID: DeviceID) async throws {
        let (destination, corrupt) = lock.withLock { count += 1; return (self.destination, self.corrupt) }
        let decoded = try FileTransferFrameCodec.decode(FileTransferFrameCodec.encode(envelope))
        guard case var .clipboardStream(message) = decoded.message, let destination else { throw ClipboardStreamFailure.unavailable }
        if corrupt, case let .range(range) = message {
            message = .range(.init(requestID: range.requestID, leaseID: UUID(), fileID: range.fileID, offset: range.offset, data: range.data))
        }
        await destination.receive(message, from: decoded.senderDeviceID)
    }
}
