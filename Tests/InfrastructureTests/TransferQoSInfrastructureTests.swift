import CryptoKit
import Foundation
import XCTest
@testable import UniSpaceInfrastructure
import UniSpaceApplication
import UniSpaceDomain

final class TransferQoSInfrastructureTests: XCTestCase {
    func testPolicyProtectsInteractiveAndDegradedControlSessions() {
        let peer = DeviceID()
        let otherPeer = DeviceID()
        let configuration = FileTransferQoSConfiguration.default

        XCTAssertEqual(
            configuration.policy(for: peer, quality: .idle).mode,
            .throughput
        )
        let interactive = configuration.policy(
            for: peer,
            quality: FileTransferControlQuality(
                isControlActive: true,
                activePeerID: peer,
                latencyMilliseconds: 12
            )
        )
        XCTAssertEqual(interactive.mode, .interactive)
        XCTAssertEqual(interactive.chunkSize, 64 * 1_024)
        XCTAssertEqual(interactive.maximumOutstandingBytes, 512 * 1_024)

        let degraded = configuration.policy(
            for: peer,
            quality: FileTransferControlQuality(
                isControlActive: true,
                activePeerID: peer,
                latencyMilliseconds: 45
            )
        )
        XCTAssertEqual(degraded.mode, .degraded)
        XCTAssertEqual(degraded.maximumOutstandingBytes, 256 * 1_024)

        XCTAssertEqual(
            configuration.policy(
                for: otherPeer,
                quality: FileTransferControlQuality(
                    isControlActive: true,
                    activePeerID: peer,
                    latencyMilliseconds: 45
                )
            ).mode,
            .interactive
        )
    }

    func testQoSTransportFragmentsBulkChunksWhileControlIsActive() async throws {
        let underlying = QoSTransportSpy()
        let transport = QoSFileTransferTransport(underlying: underlying)
        let fixture = QoSTransportFixture()
        try await transport.start(
            localDevice: fixture.local,
            workspace: fixture.workspace,
            key: Data(repeating: 7, count: 32)
        )
        await transport.updateControlQuality(FileTransferControlQuality(
            isControlActive: true,
            activePeerID: fixture.remote.id,
            latencyMilliseconds: 10
        ))

        let payload = Data(repeating: 9, count: 256 * 1_024)
        let entryID = TransferEntryID()
        try await transport.send(
            fixture.envelope(message: .chunk(TransferChunk(
                transferID: fixture.transferID,
                entryID: entryID,
                offset: 0,
                data: payload
            ))),
            to: fixture.remote.id
        )

        let chunks = underlying.sentMessages().compactMap { envelope -> TransferChunk? in
            guard case let .chunk(chunk) = envelope.message else { return nil }
            return chunk
        }
        XCTAssertEqual(chunks.count, 4)
        XCTAssertTrue(chunks.allSatisfy { $0.data.count == 64 * 1_024 })
        XCTAssertEqual(chunks.map(\.offset), [0, 65_536, 131_072, 196_608])
        await transport.stop()
    }

    func testQoSTransportBlocksAtOutstandingWindowUntilReceiverAcknowledges() async throws {
        let underlying = QoSTransportSpy()
        let configuration = FileTransferQoSConfiguration(
            throughputChunkSize: 64 * 1_024,
            interactiveChunkSize: 64 * 1_024,
            degradedChunkSize: 64 * 1_024,
            throughputOutstandingBytes: 64 * 1_024,
            interactiveOutstandingBytes: 64 * 1_024,
            degradedOutstandingBytes: 64 * 1_024,
            interactiveBytesPerSecond: nil,
            degradedBytesPerSecond: nil
        )
        let transport = QoSFileTransferTransport(
            underlying: underlying,
            configuration: configuration
        )
        let fixture = QoSTransportFixture()
        try await transport.start(
            localDevice: fixture.local,
            workspace: fixture.workspace,
            key: Data(repeating: 7, count: 32)
        )
        await transport.updateControlQuality(FileTransferControlQuality(
            isControlActive: true,
            activePeerID: fixture.remote.id
        ))
        try? await Task.sleep(for: .milliseconds(20))

        let entryID = TransferEntryID()
        let sendTask = Task {
            try await transport.send(
                fixture.envelope(message: .chunk(TransferChunk(
                    transferID: fixture.transferID,
                    entryID: entryID,
                    offset: 0,
                    data: Data(repeating: 1, count: 128 * 1_024)
                ))),
                to: fixture.remote.id
            )
        }

        let firstChunkSent = await eventually {
            underlying.chunkCount() == 1
        }
        XCTAssertTrue(firstChunkSent)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(underlying.chunkCount(), 1)

        underlying.emit(.message(
            fixture.remote.id,
            FileTransferEnvelope(
                workspaceID: fixture.workspace.id,
                senderDeviceID: fixture.remote.id,
                message: .acknowledgement(TransferAcknowledgement(
                    transferID: fixture.transferID,
                    entryID: entryID,
                    verifiedOffset: 64 * 1_024
                ))
            )
        ))

        try await sendTask.value
        XCTAssertEqual(underlying.chunkCount(), 2)
        let diagnostics = await transport.diagnostics(
            peer: fixture.remote.id,
            transferID: fixture.transferID,
            entryID: entryID
        )
        XCTAssertEqual(diagnostics.outstandingBytes, 64 * 1_024)
        await transport.stop()
    }

    func testCheckpointingStoreKeepsHandleOpenAndPersistsOnlyAtCheckpoint() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("checkpointed payload".utf8)
        let entry = TransferManifestEntry(
            filename: "payload.txt",
            byteCount: UInt64(payload.count),
            sha256: Data(SHA256.hash(data: payload))
        )
        let manifest = makeManifest(entry: entry)
        let store = CheckpointingTransferStore(
            rootURL: root,
            checkpointConfiguration: TransferCheckpointConfiguration(
                byteInterval: 1_024 * 1_024,
                minimumIntervalNanoseconds: 10_000_000_000,
                maximumIntervalNanoseconds: 10_000_000_000
            )
        )

        try await store.prepareIncoming(manifest: manifest, limits: .default)
        let split = payload.count / 2
        let first = try await store.write(TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: 0,
            data: Data(payload.prefix(split))
        ), limits: .default)
        let second = try await store.write(TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: first,
            data: Data(payload.dropFirst(split))
        ), limits: .default)
        XCTAssertEqual(second, UInt64(payload.count))

        var diagnostics = await store.diagnostics()
        XCTAssertEqual(diagnostics.openHandleCount, 1)
        XCTAssertEqual(diagnostics.handleOpenCount, 1)
        XCTAssertEqual(diagnostics.checkpointCount, 0)
        let durableBeforeSuspend = try await store.verifiedOffsets(for: manifest.transferID)
        XCTAssertEqual(durableBeforeSuspend.first?.offset, 0)

        await store.suspend(manifest.transferID)
        diagnostics = await store.diagnostics()
        XCTAssertEqual(diagnostics.openHandleCount, 0)
        XCTAssertEqual(diagnostics.checkpointCount, 1)
        let durableAfterSuspend = try await store.verifiedOffsets(for: manifest.transferID)
        XCTAssertEqual(durableAfterSuspend.first?.offset, UInt64(payload.count))

        let staged = try await store.finalizeEntry(
            transferID: manifest.transferID,
            entryID: entry.id
        )
        XCTAssertEqual(try Data(contentsOf: staged), payload)
        _ = try await store.finalizeTransfer(manifest.transferID)
    }

    func testCheckpointingStorePersistsDirtySessionWhenWritesPause() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = CheckpointTestClock()
        let payload = Data("paused transfer".utf8)
        let entry = TransferManifestEntry(
            filename: "payload.txt",
            byteCount: UInt64(payload.count),
            sha256: Data(SHA256.hash(data: payload))
        )
        let manifest = makeManifest(entry: entry)
        let store = CheckpointingTransferStore(
            rootURL: root,
            checkpointConfiguration: TransferCheckpointConfiguration(
                byteInterval: 1_024 * 1_024,
                minimumIntervalNanoseconds: 10,
                maximumIntervalNanoseconds: 100
            ),
            clock: clock
        )

        try await store.prepareIncoming(manifest: manifest, limits: .default)
        _ = try await store.write(TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: 0,
            data: payload
        ), limits: .default)
        let offsetBeforeDeadline = try await store.verifiedOffsets(for: manifest.transferID)
        XCTAssertEqual(offsetBeforeDeadline.first?.offset, 0)

        let timerScheduled = await eventually { clock.pendingSleepCount == 1 }
        XCTAssertTrue(timerScheduled)
        clock.advance(by: 100)

        let checkpointed = await eventually {
            await store.diagnostics().checkpointCount == 1
        }
        XCTAssertTrue(checkpointed)
        let offsetAfterDeadline = try await store.verifiedOffsets(for: manifest.transferID)
        XCTAssertEqual(offsetAfterDeadline.first?.offset, UInt64(payload.count))
    }

    func testStreamingSourceUsesOneHandleForSequentialReads() async throws {
        let metadataRoot = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: metadataRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let sourceURL = sourceRoot.appendingPathComponent("source.bin")
        let payload = Data(repeating: 4, count: 256 * 1_024)
        try payload.write(to: sourceURL)

        let provider = StreamingPersistentFileSourceProvider(
            rootURL: metadataRoot,
            configuration: StreamingFileSourceConfiguration(
                validationByteInterval: 16 * 1_024 * 1_024,
                validationTimeIntervalNanoseconds: 10_000_000_000
            )
        )
        let transferID = TransferID()
        let prepared = try await provider.prepare(
            urls: [sourceURL],
            transferID: transferID,
            workspaceID: WorkspaceID(),
            sourceDeviceID: DeviceID(),
            destinationDeviceID: DeviceID(),
            limits: .default
        )
        let entry = try XCTUnwrap(prepared.manifest.entries.first)
        let first = try await provider.readChunk(
            transferID: transferID,
            entryID: entry.id,
            offset: 0,
            maximumLength: 64 * 1_024
        )
        let second = try await provider.readChunk(
            transferID: transferID,
            entryID: entry.id,
            offset: UInt64(first.count),
            maximumLength: 64 * 1_024
        )
        XCTAssertEqual(first + second, Data(payload.prefix(128 * 1_024)))

        var diagnostics = await provider.diagnostics()
        XCTAssertEqual(diagnostics.openHandleCount, 1)
        XCTAssertEqual(diagnostics.handleOpenCount, 1)

        await provider.suspend(transferID)
        diagnostics = await provider.diagnostics()
        XCTAssertEqual(diagnostics.openHandleCount, 0)
        _ = try await provider.readChunk(
            transferID: transferID,
            entryID: entry.id,
            offset: 0,
            maximumLength: 64 * 1_024
        )
        diagnostics = await provider.diagnostics()
        XCTAssertEqual(diagnostics.handleOpenCount, 2)
        await provider.removeOutgoingTransfer(transferID)
    }

    private func makeManifest(entry: TransferManifestEntry) -> TransferManifest {
        TransferManifest(
            workspaceID: WorkspaceID(),
            sourceDeviceID: DeviceID(),
            destinationDeviceID: DeviceID(),
            entries: [entry]
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private final class CheckpointTestClock: MonotonicClock, @unchecked Sendable {
    private struct Waiter {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var value: UInt64 = 0
    private var waiters: [UUID: Waiter] = [:]

    var pendingSleepCount: Int { lock.qosTestWithLock { waiters.count } }

    func nowNanoseconds() -> UInt64 { lock.qosTestWithLock { value } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = lock.qosTestWithLock { () -> Bool in
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
            let continuation = self.lock.qosTestWithLock {
                self.waiters.removeValue(forKey: id)?.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by nanoseconds: UInt64) {
        let due = lock.qosTestWithLock { () -> [CheckedContinuation<Void, Error>] in
            value &+= nanoseconds
            let ids = waiters.compactMap { $0.value.deadline <= value ? $0.key : nil }
            return ids.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        }
        due.forEach { $0.resume() }
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(max(components.seconds, 0))
        let attoseconds = UInt64(max(components.attoseconds, 0))
        return seconds &* 1_000_000_000 &+ attoseconds / 1_000_000_000
    }
}

private struct QoSTransportFixture {
    let local = DeviceDescriptor(id: DeviceID(), name: "Local")
    let remote = DeviceDescriptor(id: DeviceID(), name: "Remote")
    let transferID = TransferID()
    let workspace: WorkspaceSnapshot

    init() {
        workspace = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "QoS",
            localDeviceID: local.id,
            devices: [local, remote]
        )
    }

    func envelope(message: FileTransferMessage) -> FileTransferEnvelope {
        FileTransferEnvelope(
            workspaceID: workspace.id,
            senderDeviceID: local.id,
            message: message
        )
    }
}

private final class QoSTransportSpy: FileTransferTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<FileTransferTransportEvent>
    private let continuation: AsyncStream<FileTransferTransportEvent>.Continuation
    private var sent: [FileTransferEnvelope] = []

    init() {
        let pair = AsyncStream<FileTransferTransportEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func events() -> AsyncStream<FileTransferTransportEvent> { stream }

    func send(_ envelope: FileTransferEnvelope, to deviceID: DeviceID) async throws {
        lock.qosTestWithLock { sent.append(envelope) }
    }

    func emit(_ event: FileTransferTransportEvent) {
        continuation.yield(event)
    }

    func sentMessages() -> [FileTransferEnvelope] {
        lock.qosTestWithLock { sent }
    }

    func chunkCount() -> Int {
        lock.qosTestWithLock {
            sent.reduce(into: 0) { count, envelope in
                if case .chunk = envelope.message { count += 1 }
            }
        }
    }
}

private extension NSLock {
    func qosTestWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
