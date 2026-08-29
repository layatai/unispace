import Foundation
import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

@MainActor
final class FinderFileContinuityCoordinatorTests: XCTestCase {
    func testCopiedMultiItemSelectionCreatesOneTransferOffer() async throws {
        let fixture = FinderCoordinatorFixture()
        try await fixture.start(connectPeer: true)
        await fixture.coordinator.setAutomaticDestination(fixture.remote.id)
        let urls = [
            URL(fileURLWithPath: "/tmp/First.txt"),
            URL(fileURLWithPath: "/tmp/Second.txt")
        ]

        fixture.pasteboard.emit(PasteboardFileSelection(changeCount: 1, urls: urls))

        let offered = await eventually {
            fixture.transport.offers().count == 1
        }
        XCTAssertTrue(offered)
        let offer = try XCTUnwrap(fixture.transport.offers().first)
        XCTAssertEqual(offer.manifest.entries.map(\.filename), ["First.txt", "Second.txt"])
        let preparedBatches = await fixture.source.preparedBatches()
        XCTAssertEqual(preparedBatches, [urls])
        await fixture.coordinator.stop()
    }

    func testUnavailablePeerDoesNotPrepareOrOfferFinderSelection() async throws {
        let fixture = FinderCoordinatorFixture()
        try await fixture.start(connectPeer: false)
        await fixture.coordinator.setAutomaticDestination(fixture.remote.id)

        fixture.pasteboard.emit(PasteboardFileSelection(
            changeCount: 2,
            urls: [URL(fileURLWithPath: "/tmp/Offline.txt")]
        ))
        try await Task.sleep(for: .milliseconds(100))

        let preparedBatches = await fixture.source.preparedBatches()
        let snapshots = await fixture.coordinator.snapshots()
        XCTAssertEqual(preparedBatches.count, 0)
        XCTAssertTrue(fixture.transport.offers().isEmpty)
        XCTAssertTrue(snapshots.isEmpty)
        await fixture.coordinator.stop()
    }

    func testAutomaticFinderTransferCanBeCancelledIdempotently() async throws {
        let fixture = FinderCoordinatorFixture()
        try await fixture.start(connectPeer: true)
        await fixture.coordinator.setAutomaticDestination(fixture.remote.id)
        fixture.pasteboard.emit(PasteboardFileSelection(
            changeCount: 3,
            urls: [URL(fileURLWithPath: "/tmp/Cancel.txt")]
        ))

        let offered = await eventually { fixture.transport.offers().count == 1 }
        XCTAssertTrue(offered)
        let transferID = try XCTUnwrap(fixture.transport.offers().first?.manifest.transferID)
        await fixture.coordinator.cancel(transferID)
        await fixture.coordinator.cancel(transferID)

        let state = await fixture.coordinator.snapshots()
            .first(where: { $0.id == transferID })?.state
        XCTAssertEqual(state, .cancelled)
        XCTAssertEqual(fixture.transport.cancellations(for: transferID), 1)
        let removed = await fixture.source.wasRemoved(transferID)
        XCTAssertTrue(removed)
        await fixture.coordinator.stop()
    }

    func testStoppingCoordinatorPreventsLateClipboardLifecycleEvents() async throws {
        let fixture = FinderCoordinatorFixture()
        try await fixture.start(connectPeer: true)
        await fixture.coordinator.setAutomaticDestination(fixture.remote.id)
        await fixture.coordinator.stop()

        fixture.pasteboard.emit(PasteboardFileSelection(
            changeCount: 4,
            urls: [URL(fileURLWithPath: "/tmp/Late.txt")]
        ))
        try await Task.sleep(for: .milliseconds(100))

        let preparedBatches = await fixture.source.preparedBatches()
        XCTAssertTrue(fixture.transport.offers().isEmpty)
        XCTAssertEqual(preparedBatches.count, 0)
    }

    func testRecoveredMultiItemTransferRequiresEveryMaterializedURL() {
        let local = DeviceID()
        let remote = DeviceID()
        let manifest = TransferManifest(
            workspaceID: WorkspaceID(),
            sourceDeviceID: remote,
            destinationDeviceID: local,
            entries: [
                TransferManifestEntry(
                    filename: "One.txt",
                    byteCount: 1,
                    sha256: Data(repeating: 1, count: 32)
                ),
                TransferManifestEntry(
                    filename: "Two.txt",
                    byteCount: 1,
                    sha256: Data(repeating: 2, count: 32)
                )
            ]
        )

        XCTAssertFalse(RecoveredIncomingTransfer(
            manifest: manifest,
            offsets: [],
            completedURLs: [URL(fileURLWithPath: "/tmp/One.txt")]
        ).isCompleted)
        XCTAssertFalse(RecoveredIncomingTransfer(
            manifest: manifest,
            offsets: [],
            completedURLs: [
                URL(fileURLWithPath: "/tmp/One.txt"),
                URL(fileURLWithPath: "/tmp/Wrong.txt")
            ]
        ).isCompleted)
        XCTAssertTrue(RecoveredIncomingTransfer(
            manifest: manifest,
            offsets: [],
            completedURLs: [
                URL(fileURLWithPath: "/tmp/One.txt"),
                URL(fileURLWithPath: "/tmp/Two.txt")
            ]
        ).isCompleted)
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
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
private final class FinderCoordinatorFixture {
    let local = DeviceDescriptor(id: DeviceID(), name: "Local")
    let remote = DeviceDescriptor(id: DeviceID(), name: "Remote")
    let workspace: WorkspaceSnapshot
    let transport = FinderTransportSpy()
    let source = FinderSourceSpy()
    let store = FinderStoreSpy()
    let pasteboard = FinderPasteboardSpy()
    let coordinator: FileTransferCoordinator

    init() {
        workspace = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "Finder Continuity",
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

    func start(connectPeer: Bool) async throws {
        try await coordinator.start(
            localDevice: local,
            workspace: workspace,
            key: Data(repeating: 9, count: 32)
        )
        if connectPeer {
            transport.emit(.connected(remote.id))
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while clock.now < deadline {
                let connected = await coordinator.connectedDeviceIDs()
                if connected.contains(remote.id) { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("The file-transfer peer did not connect")
        }
    }
}

private final class FinderTransportSpy: FileTransferTransport, @unchecked Sendable {
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
        lock.finderWithLock { sent.append(envelope) }
    }

    func emit(_ event: FileTransferTransportEvent) {
        continuation.yield(event)
    }

    func offers() -> [TransferOffer] {
        envelopes().compactMap {
            if case let .offer(value) = $0.message { return value }
            return nil
        }
    }

    func cancellations(for transferID: TransferID) -> Int {
        envelopes().filter {
            if case let .cancellation(value) = $0.message {
                return value.transferID == transferID
            }
            return false
        }.count
    }

    private func envelopes() -> [FileTransferEnvelope] {
        lock.finderWithLock { sent }
    }
}

private actor FinderSourceSpy: FileSourceProvider {
    private var batches: [[URL]] = []
    private var removed = Set<TransferID>()

    func prepare(
        urls: [URL],
        transferID: TransferID,
        workspaceID: WorkspaceID,
        sourceDeviceID: DeviceID,
        destinationDeviceID: DeviceID,
        limits: FileTransferLimits
    ) async throws -> PreparedOutgoingTransfer {
        batches.append(urls)
        let entries = urls.enumerated().map { index, url in
            TransferManifestEntry(
                filename: url.lastPathComponent,
                byteCount: 1,
                sha256: Data(repeating: UInt8(index + 1), count: 32)
            )
        }
        return PreparedOutgoingTransfer(manifest: TransferManifest(
            transferID: transferID,
            workspaceID: workspaceID,
            sourceDeviceID: sourceDeviceID,
            destinationDeviceID: destinationDeviceID,
            entries: entries
        ))
    }

    func readChunk(
        transferID: TransferID,
        entryID: TransferEntryID,
        offset: UInt64,
        maximumLength: Int
    ) async throws -> Data {
        Data([1])
    }

    func recoverOutgoingTransfers(limits: FileTransferLimits) async throws -> [PreparedOutgoingTransfer] {
        []
    }

    func removeOutgoingTransfer(_ transferID: TransferID) async {
        removed.insert(transferID)
    }

    func preparedBatches() -> [[URL]] { batches }
    func wasRemoved(_ transferID: TransferID) -> Bool { removed.contains(transferID) }
}

private actor FinderStoreSpy: TransferStore {
    func prepareIncoming(manifest: TransferManifest, limits: FileTransferLimits) async throws {}
    func write(_ chunk: TransferChunk, limits: FileTransferLimits) async throws -> UInt64 {
        chunk.offset + UInt64(chunk.data.count)
    }
    func verifiedOffsets(for transferID: TransferID) async throws -> [TransferEntryOffset] { [] }
    func finalizeEntry(transferID: TransferID, entryID: TransferEntryID) async throws -> URL {
        URL(fileURLWithPath: "/tmp/\(entryID.rawValue.uuidString)")
    }
    func finalizeTransfer(_ transferID: TransferID) async throws -> [URL] { [] }
    func completedURLs(for transferID: TransferID) async throws -> [URL] { [] }
    func recoverIncomingTransfers(limits: FileTransferLimits) async throws -> [RecoveredIncomingTransfer] { [] }
    func cancel(_ transferID: TransferID) async {}
    func remove(_ transferID: TransferID) async {}
    func removeExpired(now: Date, limits: FileTransferLimits) async {}
}

@MainActor
private final class FinderPasteboardSpy: FilePasteboard {
    private let stream: AsyncStream<PasteboardFileSelection>
    private let continuation: AsyncStream<PasteboardFileSelection>.Continuation

    init() {
        var captured: AsyncStream<PasteboardFileSelection>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    func events() -> AsyncStream<PasteboardFileSelection> { stream }
    func publishFiles(_ urls: [URL], transferID: TransferID) {}
    func emit(_ selection: PasteboardFileSelection) { continuation.yield(selection) }
}

private extension NSLock {
    func finderWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
