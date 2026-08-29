import Foundation
import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

@MainActor
final class FilePasteboardFailureReportingTests: XCTestCase {
    func testFailedFinderPublicationSendsRejectedVerificationToSender() async throws {
        let local = DeviceDescriptor(id: DeviceID(), name: "Local")
        let remote = DeviceDescriptor(id: DeviceID(), name: "Remote")
        let workspace = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "Finder publication failure",
            localDeviceID: local.id,
            devices: [local, remote]
        )
        let transport = PublicationFailureTransport()
        let store = PublicationFailureStore()
        let pasteboard = PublicationFailurePasteboard()
        let coordinator = FileTransferCoordinator(
            transport: transport,
            store: store,
            sourceProvider: PublicationFailureSource(),
            pasteboard: pasteboard
        )

        try await coordinator.start(
            localDevice: local,
            workspace: workspace,
            key: Data(repeating: 7, count: 32)
        )
        transport.emit(.connected(remote.id))
        XCTAssertTrue(await eventually {
            let connected = await coordinator.connectedDeviceIDs()
            return connected.contains(remote.id)
        })

        let entry = TransferManifestEntry(
            filename: "received.txt",
            byteCount: 1,
            sha256: Data(repeating: 1, count: 32)
        )
        let manifest = TransferManifest(
            workspaceID: workspace.id,
            sourceDeviceID: remote.id,
            destinationDeviceID: local.id,
            entries: [entry]
        )
        transport.emit(.message(
            remote.id,
            FileTransferEnvelope(
                workspaceID: workspace.id,
                senderDeviceID: remote.id,
                message: .offer(TransferOffer(manifest: manifest))
            )
        ))
        XCTAssertTrue(await eventually {
            transport.messages().contains {
                if case let .request(request) = $0.message {
                    return request.transferID == manifest.transferID
                }
                return false
            }
        })

        transport.emit(.message(
            remote.id,
            FileTransferEnvelope(
                workspaceID: workspace.id,
                senderDeviceID: remote.id,
                message: .transferComplete(TransferCompletion(
                    transferID: manifest.transferID
                ))
            )
        ))

        XCTAssertTrue(await eventually {
            transport.messages().contains {
                if case let .verification(verification) = $0.message {
                    return verification.transferID == manifest.transferID &&
                        !verification.accepted &&
                        verification.failureCode == .stagingFailure
                }
                return false
            }
        })
        let snapshot = (await coordinator.snapshots())
            .first(where: { $0.id == manifest.transferID })
        XCTAssertEqual(snapshot?.state, .failed)
        XCTAssertEqual(snapshot?.failureCode, .stagingFailure)
        XCTAssertEqual(snapshot?.stagedURLs, [store.stagedURL])
        XCTAssertEqual(pasteboard.publicationAttempts, 1)

        await coordinator.stop()
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

private final class PublicationFailureTransport: FileTransferTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<FileTransferTransportEvent>
    private let continuation: AsyncStream<FileTransferTransportEvent>.Continuation
    private var sent: [FileTransferEnvelope] = []

    init() {
        var captured: AsyncStream<FileTransferTransportEvent>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    func start(
        localDevice: DeviceDescriptor,
        workspace: WorkspaceSnapshot,
        key: Data
    ) async throws {}

    func stop() async {}

    func events() -> AsyncStream<FileTransferTransportEvent> {
        stream
    }

    func send(_ envelope: FileTransferEnvelope, to deviceID: DeviceID) async throws {
        lock.withPublicationFailureLock {
            sent.append(envelope)
        }
    }

    func emit(_ event: FileTransferTransportEvent) {
        continuation.yield(event)
    }

    func messages() -> [FileTransferEnvelope] {
        lock.withPublicationFailureLock { sent }
    }
}

private actor PublicationFailureStore: TransferStore {
    nonisolated let stagedURL = URL(fileURLWithPath: "/tmp/received.txt")

    func prepareIncoming(
        manifest: TransferManifest,
        limits: FileTransferLimits
    ) async throws {}

    func write(
        _ chunk: TransferChunk,
        limits: FileTransferLimits
    ) async throws -> UInt64 {
        chunk.offset + UInt64(chunk.data.count)
    }

    func verifiedOffsets(for transferID: TransferID) async throws -> [TransferEntryOffset] {
        []
    }

    func finalizeEntry(
        transferID: TransferID,
        entryID: TransferEntryID
    ) async throws -> URL {
        stagedURL
    }

    func finalizeTransfer(_ transferID: TransferID) async throws -> [URL] {
        [stagedURL]
    }

    func completedURLs(for transferID: TransferID) async throws -> [URL] {
        []
    }

    func recoverIncomingTransfers(
        limits: FileTransferLimits
    ) async throws -> [RecoveredIncomingTransfer] {
        []
    }

    func cancel(_ transferID: TransferID) async {}
    func remove(_ transferID: TransferID) async {}
    func removeExpired(now: Date, limits: FileTransferLimits) async {}
}

private actor PublicationFailureSource: FileSourceProvider {
    func prepare(
        urls: [URL],
        transferID: TransferID,
        workspaceID: WorkspaceID,
        sourceDeviceID: DeviceID,
        destinationDeviceID: DeviceID,
        limits: FileTransferLimits
    ) async throws -> PreparedOutgoingTransfer {
        throw FileTransferCoordinatorError.sourceChanged
    }

    func readChunk(
        transferID: TransferID,
        entryID: TransferEntryID,
        offset: UInt64,
        maximumLength: Int
    ) async throws -> Data {
        throw FileTransferCoordinatorError.sourceChanged
    }

    func recoverOutgoingTransfers(
        limits: FileTransferLimits
    ) async throws -> [PreparedOutgoingTransfer] {
        []
    }

    func removeOutgoingTransfer(_ transferID: TransferID) async {}
}

@MainActor
private final class PublicationFailurePasteboard: FilePasteboard {
    private let stream: AsyncStream<PasteboardFileSelection>
    private let continuation: AsyncStream<PasteboardFileSelection>.Continuation
    private(set) var publicationAttempts = 0

    init() {
        var captured: AsyncStream<PasteboardFileSelection>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    deinit {
        continuation.finish()
    }

    func events() -> AsyncStream<PasteboardFileSelection> {
        stream
    }

    func publishFiles(_ urls: [URL], transferID: TransferID) {}

    func publishFilesChecked(_ urls: [URL], transferID: TransferID) throws {
        publicationAttempts += 1
        throw FilePasteboardPublicationError.writeRejected
    }
}

private extension NSLock {
    func withPublicationFailureLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
