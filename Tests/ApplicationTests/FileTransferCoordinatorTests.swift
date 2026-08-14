import Foundation
import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class FileTransferCoordinatorTests: XCTestCase {
    func testFileTransferCodecRoundTripsAndRejectsInvalidFrames() throws {
        let local = DeviceID()
        let workspace = WorkspaceID()
        let envelope = FileTransferEnvelope(
            workspaceID: workspace,
            senderDeviceID: local,
            message: .cancellation(TransferCancellation(transferID: TransferID()))
        )
        let data = try FileTransferFrameCodec.encode(envelope)
        XCTAssertEqual(try FileTransferFrameCodec.decode(data), envelope)
        XCTAssertThrowsError(try FileTransferFrameCodec.decode(Data()))
        XCTAssertThrowsError(try FileTransferFrameCodec.decode(Data(repeating: 1, count: FileTransferFrameCodec.maximumEncodedSize + 1)))
    }

    @MainActor
    func testOutgoingTransferOffersStreamsAndCompletesAfterVerification() async throws {
        let fixture = Fixture()
        try await fixture.start()
        fixture.transport.emit(.connected(fixture.remote.id))
        await fixture.coordinator.setAutomaticDestination(fixture.remote.id)

        let transferID = try await fixture.coordinator.sendFiles([
            URL(fileURLWithPath: "/tmp/source.txt")
        ])
        XCTAssertTrue(await eventually {
            await fixture.transport.messages().contains {
                if case let .offer(value) = $0.message {
                    return value.manifest.transferID == transferID
                }
                return false
            }
        })

        let manifest = try XCTUnwrap(await fixture.source.manifest(transferID))
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .request(TransferRequest(
                transferID: transferID,
                offsets: manifest.entries.map { TransferEntryOffset(entryID: $0.id, offset: 0) }
            )))
        ))

        XCTAssertTrue(await eventually {
            let messages = await fixture.transport.messages().map(\.message)
            return messages.contains(where: {
                if case let .chunk(value) = $0 { return value.transferID == transferID }
                return false
            }) && messages.contains(where: {
                if case let .transferComplete(value) = $0 { return value.transferID == transferID }
                return false
            })
        })

        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .verification(
                TransferVerification(transferID: transferID, accepted: true)
            ))
        ))
        XCTAssertTrue(await eventually {
            await fixture.coordinator.snapshots().first(where: { $0.id == transferID })?.state == .completed
        })
        XCTAssertTrue(await fixture.source.wasRemoved(transferID))
        await fixture.coordinator.stop()
    }

    @MainActor
    func testIncomingTransferStagesPublishesAndAcknowledges() async throws {
        let fixture = Fixture()
        try await fixture.start()
        fixture.transport.emit(.connected(fixture.remote.id))
        let entry = TransferManifestEntry(
            filename: "received.txt",
            byteCount: 4,
            sha256: Data(repeating: 2, count: 32)
        )
        let manifest = TransferManifest(
            workspaceID: fixture.workspace.id,
            sourceDeviceID: fixture.remote.id,
            destinationDeviceID: fixture.local.id,
            entries: [entry]
        )
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .offer(TransferOffer(manifest: manifest)))
        ))

        XCTAssertTrue(await eventually {
            await fixture.transport.messages().contains {
                if case let .request(value) = $0.message {
                    return value.transferID == manifest.transferID
                }
                return false
            }
        })

        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .chunk(TransferChunk(
                transferID: manifest.transferID,
                entryID: entry.id,
                offset: 0,
                data: Data([1, 2, 3, 4])
            )))
        ))
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .entryComplete(
                TransferEntryCompletion(transferID: manifest.transferID, entryID: entry.id)
            ))
        ))
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .transferComplete(
                TransferCompletion(transferID: manifest.transferID)
            ))
        ))

        XCTAssertTrue(await eventually {
            await fixture.coordinator.snapshots().first(where: { $0.id == manifest.transferID })?.state == .completed
        })
        XCTAssertEqual(fixture.pasteboard.publishedTransferID, manifest.transferID)
        XCTAssertEqual(fixture.pasteboard.publishedURLs.map(\.lastPathComponent), ["received.txt"])
        XCTAssertTrue(await fixture.transport.messages().contains {
            if case let .verification(value) = $0.message {
                return value.transferID == manifest.transferID && value.accepted
            }
            return false
        })
        await fixture.coordinator.stop()
    }

    @MainActor
    func testDisconnectPausesAndReconnectQueriesResumeState() async throws {
        let fixture = Fixture()
        try await fixture.start()
        fixture.transport.emit(.connected(fixture.remote.id))
        let transferID = try await fixture.coordinator.sendFiles(
            [URL(fileURLWithPath: "/tmp/source.txt")],
            to: fixture.remote.id
        )
        let manifest = try XCTUnwrap(await fixture.source.manifest(transferID))
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .request(TransferRequest(
                transferID: transferID,
                offsets: manifest.entries.map { TransferEntryOffset(entryID: $0.id, offset: 0) }
            )))
        ))
        fixture.transport.emit(.disconnected(fixture.remote.id))
        XCTAssertTrue(await eventually {
            await fixture.coordinator.snapshots().first(where: { $0.id == transferID })?.state == .paused
        })
        let countBeforeReconnect = await fixture.transport.messages().count
        fixture.transport.emit(.connected(fixture.remote.id))
        XCTAssertTrue(await eventually {
            let messages = await fixture.transport.messages().dropFirst(countBeforeReconnect)
            return messages.contains {
                if case let .resumeQuery(value) = $0.message {
                    return value.transferID == transferID
                }
                return false
            }
        })
        await fixture.coordinator.stop()
    }

    @MainActor
    func testCancellationIsIdempotentAndRemovesStaging() async throws {
        let fixture = Fixture()
        try await fixture.start()
        fixture.transport.emit(.connected(fixture.remote.id))
        let transferID = try await fixture.coordinator.sendFiles(
            [URL(fileURLWithPath: "/tmp/source.txt")],
            to: fixture.remote.id
        )
        await fixture.coordinator.cancel(transferID)
        await fixture.coordinator.cancel(transferID)
        XCTAssertEqual(
            await fixture.coordinator.snapshots().first(where: { $0.id == transferID })?.state,
            .cancelled
        )
        XCTAssertTrue(await fixture.source.wasRemoved(transferID))
        await fixture.coordinator.stop()
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}

@MainActor
private final class Fixture {
    let local = DeviceDescriptor(id: DeviceID(), name: "Local")
    let remote = DeviceDescriptor(id: DeviceID(), name: "Remote")
    let workspace: WorkspaceSnapshot
    let transport = FileTransferTransportSpy()
    let store = TransferStoreSpy()
    let source = FileSourceProviderSpy()
    let pasteboard = FilePasteboardSpy()
    let coordinator: FileTransferCoordinator

    init() {
        workspace = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "Test",
            localDeviceID: local.id,
            devices: [local, remote]
        )
        coordinator = FileTransferCoordinator(
            transport: transport,
            store: store,
            sourceProvider: source,
            pasteboard: pasteboard
        )
    }

    func start() async throws {
        try await coordinator.start(
            localDevice: local,
            workspace: workspace,
            key: Data(repeating: 9, count: 32)
        )
    }

    func envelope(from sender: DeviceID, message: FileTransferMessage) -> FileTransferEnvelope {
        FileTransferEnvelope(
            workspaceID: workspace.id,
            senderDeviceID: sender,
            message: message
        )
    }
}

private final class FileTransferTransportSpy: FileTransferTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<FileTransferTransportEvent>
    private let continuation: AsyncStream<FileTransferTransportEvent>.Continuation
    private var sent: [FileTransferEnvelope] = []

    init() {
        var captured: AsyncStream<FileTransferTransportEvent>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func events() -> AsyncStream<FileTransferTransportEvent> { stream }

    func send(_ envelope: FileTransferEnvelope, to deviceID: DeviceID) async throws {
        lock.lock()
        sent.append(envelope)
        lock.unlock()
    }

    func emit(_ event: FileTransferTransportEvent) {
        continuation.yield(event)
    }

    func messages() async -> [FileTransferEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }
}

private actor FileSourceProviderSpy: FileSourceProvider {
    private var manifests: [TransferID: TransferManifest] = [:]
    private var payloads: [TransferID: Data] = [:]
    private var removed = Set<TransferID>()

    func prepare(
        urls: [URL],
        transferID: TransferID,
        workspaceID: WorkspaceID,
        sourceDeviceID: DeviceID,
        destinationDeviceID: DeviceID,
        limits: FileTransferLimits
    ) async throws -> PreparedOutgoingTransfer {
        let data = Data([1, 2, 3, 4])
        let manifest = TransferManifest(
            transferID: transferID,
            workspaceID: workspaceID,
            sourceDeviceID: sourceDeviceID,
            destinationDeviceID: destinationDeviceID,
            entries: [TransferManifestEntry(
                filename: urls.first?.lastPathComponent ?? "source.txt",
                byteCount: UInt64(data.count),
                sha256: Data(repeating: 1, count: 32)
            )]
        )
        manifests[transferID] = manifest
        payloads[transferID] = data
        return PreparedOutgoingTransfer(manifest: manifest)
    }

    func readChunk(
        transferID: TransferID,
        entryID: TransferEntryID,
        offset: UInt64,
        maximumLength: Int
    ) async throws -> Data {
        guard let data = payloads[transferID] else { throw FileTransferCoordinatorError.sourceChanged }
        let start = Int(offset)
        guard start <= data.count else { throw FileTransferCoordinatorError.sourceChanged }
        return data.subdata(in: start..<min(start + maximumLength, data.count))
    }

    func recoverOutgoingTransfers(limits: FileTransferLimits) async throws -> [PreparedOutgoingTransfer] { [] }

    func removeOutgoingTransfer(_ transferID: TransferID) async {
        removed.insert(transferID)
    }

    func manifest(_ transferID: TransferID) -> TransferManifest? { manifests[transferID] }
    func wasRemoved(_ transferID: TransferID) -> Bool { removed.contains(transferID) }
}

private actor TransferStoreSpy: TransferStore {
    private var manifests: [TransferID: TransferManifest] = [:]
    private var offsets: [TransferID: [TransferEntryID: UInt64]] = [:]
    private var finalized: [TransferID: [URL]] = [:]

    func prepareIncoming(manifest: TransferManifest, limits: FileTransferLimits) async throws {
        manifests[manifest.transferID] = manifest
        offsets[manifest.transferID] = Dictionary(
            uniqueKeysWithValues: manifest.entries.map { ($0.id, 0) }
        )
    }

    func write(_ chunk: TransferChunk, limits: FileTransferLimits) async throws -> UInt64 {
        let next = chunk.offset + UInt64(chunk.data.count)
        offsets[chunk.transferID]?[chunk.entryID] = next
        return next
    }

    func verifiedOffsets(for transferID: TransferID) async throws -> [TransferEntryOffset] {
        guard let manifest = manifests[transferID] else { return [] }
        return manifest.entries.map {
            TransferEntryOffset(entryID: $0.id, offset: offsets[transferID]?[$0.id] ?? 0)
        }
    }

    func finalizeEntry(transferID: TransferID, entryID: TransferEntryID) async throws -> URL {
        guard let entry = manifests[transferID]?.entry(id: entryID) else {
            throw FileTransferProtocolError.unknownEntry(entryID)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(entry.filename)
        finalized[transferID, default: []].append(url)
        return url
    }

    func finalizeTransfer(_ transferID: TransferID) async throws -> [URL] {
        finalized[transferID] ?? []
    }

    func completedURLs(for transferID: TransferID) async throws -> [URL] {
        finalized[transferID] ?? []
    }

    func recoverIncomingTransfers(limits: FileTransferLimits) async throws -> [RecoveredIncomingTransfer] { [] }
    func cancel(_ transferID: TransferID) async { manifests.removeValue(forKey: transferID) }
    func remove(_ transferID: TransferID) async { manifests.removeValue(forKey: transferID) }
    func removeExpired(now: Date, limits: FileTransferLimits) async {}
}

@MainActor
private final class FilePasteboardSpy: FilePasteboard {
    private let stream: AsyncStream<PasteboardFileSelection>
    private let continuation: AsyncStream<PasteboardFileSelection>.Continuation
    private(set) var publishedURLs: [URL] = []
    private(set) var publishedTransferID: TransferID?

    init() {
        var captured: AsyncStream<PasteboardFileSelection>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    func events() -> AsyncStream<PasteboardFileSelection> { stream }

    func publishFiles(_ urls: [URL], transferID: TransferID) {
        publishedURLs = urls
        publishedTransferID = transferID
    }

    func emit(_ selection: PasteboardFileSelection) {
        continuation.yield(selection)
    }
}
