import Foundation
import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class FileTransferCoordinatorTests: XCTestCase {
    @MainActor
    func testCoordinatorEmitsBoundedResyncAfterEventOverflow() async throws {
        let fixture = FileTransferFixture()
        let recovered = (0..<130).map { index in
            RecoveredIncomingTransfer(
                manifest: fixture.makeManifest(
                    source: fixture.remote.id,
                    destination: fixture.local.id,
                    filename: "file-\(index).txt"
                ),
                offsets: []
            )
        }
        await fixture.store.setRecovered(recovered)
        let events = await fixture.coordinator.events()

        try await fixture.coordinator.start(
            localDevice: fixture.local,
            workspace: fixture.workspace,
            key: Data(repeating: 9, count: 32)
        )

        var iterator = events.makeAsyncIterator()
        var resyncedSnapshots: [FileTransferSnapshot]?
        for _ in 0..<128 {
            guard let event = await iterator.next() else {
                return XCTFail("Expected a full bounded event buffer")
            }
            if case let .resync(snapshots) = event {
                resyncedSnapshots = snapshots
            }
        }
        XCTAssertEqual(resyncedSnapshots?.count, 130)
        XCTAssertTrue(resyncedSnapshots?.allSatisfy { $0.state == .paused } == true)
    }

    func testFileTransferContractsExposeProgressRecoveryAndActionableErrors() {
        let transferID = TransferID()
        let peer = DeviceID()
        let active = FileTransferSnapshot(
            id: transferID,
            direction: .outgoing,
            peerDeviceID: peer,
            displayName: "Active",
            fileCount: 1,
            totalByteCount: 4,
            transferredByteCount: 10,
            state: .transferring,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(active.transferredByteCount, 4)
        XCTAssertEqual(active.progress, 1)
        XCTAssertTrue(active.isActive)

        let emptyCompleted = FileTransferSnapshot(
            id: TransferID(),
            direction: .incoming,
            peerDeviceID: peer,
            displayName: "Empty",
            fileCount: 0,
            totalByteCount: 0,
            transferredByteCount: 0,
            state: .completed,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(emptyCompleted.progress, 1)
        XCTAssertFalse(emptyCompleted.isActive)

        let manifest = TransferManifest(
            workspaceID: WorkspaceID(),
            sourceDeviceID: peer,
            destinationDeviceID: DeviceID(),
            entries: [TransferManifestEntry(
                filename: "file.txt",
                byteCount: 1,
                sha256: Data(repeating: 1, count: 32)
            )]
        )
        XCTAssertEqual(PreparedOutgoingTransfer(manifest: manifest).manifest, manifest)
        XCTAssertFalse(RecoveredIncomingTransfer(manifest: manifest, offsets: []).isCompleted)
        XCTAssertTrue(RecoveredIncomingTransfer(
            manifest: manifest,
            offsets: [],
            completedURLs: [URL(fileURLWithPath: "/tmp/file.txt")]
        ).isCompleted)
        XCTAssertEqual(PasteboardFileSelection(
            changeCount: 3,
            urls: [URL(fileURLWithPath: "/tmp/file.txt")]
        ).changeCount, 3)

        let descriptions: [(FileTransferCoordinatorError, String)] = [
            (.noDestination, "Choose an online Mac before sending files."),
            (.peerUnavailable(peer), "The destination Mac is not available for file transfer."),
            (.peerBusy(peer), "Another file transfer is already active for that Mac."),
            (.transferNotFound(transferID), "The transfer no longer exists."),
            (.invalidState(.offered), "The transfer cannot perform that action in its current state."),
            (.sourceChanged, "A source file changed while it was being transferred."),
            (.transferRejected, "The destination Mac rejected the transfer."),
        ]
        for (error, description) in descriptions {
            XCTAssertEqual(error.errorDescription, description)
        }
    }

    @MainActor
    func testLegacyPasteboardCheckedPublicationUsesCompatibilityEntryPoint() throws {
        let pasteboard = LegacyFilePasteboardSpy()
        let transferID = TransferID()
        let urls = [URL(fileURLWithPath: "/tmp/legacy.txt")]

        try pasteboard.publishFilesChecked(urls, transferID: transferID)

        XCTAssertEqual(pasteboard.publishedURLs, urls)
        XCTAssertEqual(pasteboard.publishedTransferID, transferID)
    }

    func testFileTransferCodecRoundTripsAndRejectsInvalidFrames() throws {
        let envelope = FileTransferEnvelope(
            workspaceID: WorkspaceID(),
            senderDeviceID: DeviceID(),
            message: .cancellation(TransferCancellation(transferID: TransferID()))
        )
        let data = try FileTransferFrameCodec.encode(envelope)
        XCTAssertEqual(try FileTransferFrameCodec.decode(data), envelope)
        XCTAssertThrowsError(try FileTransferFrameCodec.decode(Data()))
        XCTAssertThrowsError(try FileTransferFrameCodec.decode(
            Data(repeating: 1, count: FileTransferFrameCodec.maximumEncodedSize + 1)
        ))
    }

    @MainActor
    func testOutgoingTransferStreamsAndCompletesAfterVerification() async throws {
        let fixture = FileTransferFixture()
        try await fixture.startAndConnect()

        let transferID = try await fixture.coordinator.sendFiles(
            [URL(fileURLWithPath: "/tmp/source.txt")],
            to: fixture.remote.id
        )
        let offered = await eventually {
            fixture.transport.messages().contains {
                if case let .offer(value) = $0.message {
                    return value.manifest.transferID == transferID
                }
                return false
            }
        }
        XCTAssertTrue(offered)

        let optionalManifest = await fixture.source.manifest(transferID)
        let manifest = try XCTUnwrap(optionalManifest)
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .request(TransferRequest(
                transferID: transferID,
                offsets: manifest.entries.map {
                    TransferEntryOffset(entryID: $0.id, offset: 0)
                }
            )))
        ))

        let streamed = await eventually {
            let messages = fixture.transport.messages().map(\.message)
            return messages.contains(where: {
                if case let .chunk(value) = $0 { return value.transferID == transferID }
                return false
            }) && messages.contains(where: {
                if case let .transferComplete(value) = $0 {
                    return value.transferID == transferID
                }
                return false
            })
        }
        XCTAssertTrue(streamed)

        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .verification(
                TransferVerification(transferID: transferID, accepted: true)
            ))
        ))
        let completed = await eventually {
            await fixture.coordinator.snapshots()
                .first(where: { $0.id == transferID })?.state == .completed
        }
        XCTAssertTrue(completed)
        let removed = await fixture.source.wasRemoved(transferID)
        XCTAssertTrue(removed)
        await fixture.coordinator.stop()
    }

    @MainActor
    func testIncomingTransferPublishesOnlyAfterCompletion() async throws {
        let fixture = FileTransferFixture()
        try await fixture.startAndConnect()
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
            fixture.envelope(from: fixture.remote.id, message: .offer(
                TransferOffer(manifest: manifest)
            ))
        ))

        let requested = await eventually {
            fixture.transport.messages().contains {
                if case let .request(value) = $0.message {
                    return value.transferID == manifest.transferID
                }
                return false
            }
        }
        XCTAssertTrue(requested)
        XCTAssertNil(fixture.pasteboard.publishedTransferID)

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

        let completed = await eventually {
            await fixture.coordinator.snapshots()
                .first(where: { $0.id == manifest.transferID })?.state == .completed
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(fixture.pasteboard.publishedTransferID, manifest.transferID)
        XCTAssertEqual(fixture.pasteboard.publishedURLs.map(\.lastPathComponent), ["received.txt"])
        let verified = fixture.transport.messages().contains {
            if case let .verification(value) = $0.message {
                return value.transferID == manifest.transferID && value.accepted
            }
            return false
        }
        XCTAssertTrue(verified)
        await fixture.coordinator.stop()
    }

    @MainActor
    func testIncomingTransferRejectsFailedFinderPublication() async throws {
        let fixture = FileTransferFixture()
        fixture.pasteboard.publicationError = FilePasteboardPublicationError.writeRejected
        try await fixture.startAndConnect()
        let entry = TransferManifestEntry(
            filename: "received.txt",
            byteCount: 1,
            sha256: Data(repeating: 7, count: 32)
        )
        let manifest = TransferManifest(
            workspaceID: fixture.workspace.id,
            sourceDeviceID: fixture.remote.id,
            destinationDeviceID: fixture.local.id,
            entries: [entry]
        )
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .offer(
                TransferOffer(manifest: manifest)
            ))
        ))
        let requested = await eventually {
            fixture.transport.messages().contains {
                if case let .request(request) = $0.message {
                    return request.transferID == manifest.transferID
                }
                return false
            }
        }
        XCTAssertTrue(requested)

        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .transferComplete(
                TransferCompletion(transferID: manifest.transferID)
            ))
        ))

        let failed = await eventually {
            await fixture.coordinator.snapshots()
                .first(where: { $0.id == manifest.transferID })?.state == .failed
        }
        XCTAssertTrue(failed)
        let verification = fixture.transport.messages().compactMap { envelope -> TransferVerification? in
            guard case let .verification(value) = envelope.message,
                  value.transferID == manifest.transferID else { return nil }
            return value
        }.last
        XCTAssertEqual(verification?.accepted, false)
        XCTAssertEqual(verification?.failureCode, .stagingFailure)
        XCTAssertEqual(fixture.pasteboard.publicationAttempts, 1)
        await fixture.coordinator.stop()
    }

    @MainActor
    func testDuplicateReceivedChunkIsIdempotent() async throws {
        let fixture = FileTransferFixture()
        try await fixture.startAndConnect()
        let entry = TransferManifestEntry(
            filename: "duplicate.bin",
            byteCount: 4,
            sha256: Data(repeating: 3, count: 32)
        )
        let manifest = TransferManifest(
            workspaceID: fixture.workspace.id,
            sourceDeviceID: fixture.remote.id,
            destinationDeviceID: fixture.local.id,
            entries: [entry]
        )
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .offer(
                TransferOffer(manifest: manifest)
            ))
        ))
        let ready = await eventually {
            await fixture.coordinator.snapshots()
                .first(where: { $0.id == manifest.transferID })?.state == .transferring
        }
        XCTAssertTrue(ready)

        let chunk = TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: 0,
            data: Data([1, 2, 3, 4])
        )
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .chunk(chunk))
        ))
        let written = await eventually {
            await fixture.store.offset(
                transferID: manifest.transferID,
                entryID: entry.id
            ) == 4
        }
        XCTAssertTrue(written)
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .chunk(chunk))
        ))
        let acknowledgedTwice = await eventually {
            fixture.transport.messages().filter {
                if case let .acknowledgement(value) = $0.message {
                    return value.transferID == manifest.transferID && value.verifiedOffset == 4
                }
                return false
            }.count >= 2
        }
        XCTAssertTrue(acknowledgedTwice)
        let writeCount = await fixture.store.writeCount()
        XCTAssertEqual(writeCount, 1)
        await fixture.coordinator.stop()
    }

    @MainActor
    func testDisconnectPausesAndReconnectQueriesResumeState() async throws {
        let fixture = FileTransferFixture()
        try await fixture.startAndConnect()
        let transferID = try await fixture.coordinator.sendFiles(
            [URL(fileURLWithPath: "/tmp/source.txt")],
            to: fixture.remote.id
        )
        let optionalManifest = await fixture.source.manifest(transferID)
        let manifest = try XCTUnwrap(optionalManifest)
        fixture.transport.setChunkSendsBlocked(true)
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .request(TransferRequest(
                transferID: transferID,
                offsets: manifest.entries.map {
                    TransferEntryOffset(entryID: $0.id, offset: 0)
                }
            )))
        ))
        let transferring = await eventually {
            await fixture.coordinator.snapshots()
                .first(where: { $0.id == transferID })?.state == .transferring
        }
        XCTAssertTrue(transferring)

        fixture.transport.emit(.disconnected(fixture.remote.id))
        let paused = await eventually {
            await fixture.coordinator.snapshots()
                .first(where: { $0.id == transferID })?.state == .paused
        }
        XCTAssertTrue(paused)
        let countBeforeReconnect = fixture.transport.messages().count
        fixture.transport.emit(.connected(fixture.remote.id))
        let queried = await eventually {
            fixture.transport.messages().dropFirst(countBeforeReconnect).contains {
                if case let .resumeQuery(value) = $0.message {
                    return value.transferID == transferID
                }
                return false
            }
        }
        XCTAssertTrue(queried)
        await fixture.coordinator.stop()
    }

    @MainActor
    func testReplacementOutgoingTaskRemainsRegisteredForDisconnectCancellation() async throws {
        let fixture = FileTransferFixture()
        try await fixture.startAndConnect()
        fixture.transport.setChunkSendsBlocked(true)
        let transferID = try await fixture.coordinator.sendFiles(
            [URL(fileURLWithPath: "/tmp/source.txt")],
            to: fixture.remote.id
        )
        let optionalManifest = await fixture.source.manifest(transferID)
        let manifest = try XCTUnwrap(optionalManifest)
        let request = FileTransferMessage.request(TransferRequest(
            transferID: transferID,
            offsets: manifest.entries.map {
                TransferEntryOffset(entryID: $0.id, offset: 0)
            }
        ))

        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: request)
        ))
        let firstTaskStarted = await eventually { fixture.transport.chunkSendAttemptCount() == 1 }
        XCTAssertTrue(firstTaskStarted)

        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: request)
        ))
        let replacementStarted = await eventually { fixture.transport.chunkSendAttemptCount() == 2 }
        XCTAssertTrue(replacementStarted)

        fixture.transport.emit(.disconnected(fixture.remote.id))
        let allCancelled = await eventually { fixture.transport.activeChunkSendCount() == 0 }
        XCTAssertTrue(allCancelled)
        XCTAssertEqual(fixture.transport.cancelledChunkSendCount(), 2)
        await fixture.coordinator.stop()
    }

    @MainActor
    func testOnlyOneActiveOutgoingTransferPerPeer() async throws {
        let fixture = FileTransferFixture()
        try await fixture.startAndConnect()
        _ = try await fixture.coordinator.sendFiles(
            [URL(fileURLWithPath: "/tmp/first.txt")],
            to: fixture.remote.id
        )
        do {
            _ = try await fixture.coordinator.sendFiles(
                [URL(fileURLWithPath: "/tmp/second.txt")],
                to: fixture.remote.id
            )
            XCTFail("Expected peer-busy error")
        } catch let error as FileTransferCoordinatorError {
            XCTAssertEqual(error, .peerBusy(fixture.remote.id))
        }
        await fixture.coordinator.stop()
    }

    @MainActor
    func testCancellationIsIdempotent() async throws {
        let fixture = FileTransferFixture()
        try await fixture.startAndConnect()
        let transferID = try await fixture.coordinator.sendFiles(
            [URL(fileURLWithPath: "/tmp/source.txt")],
            to: fixture.remote.id
        )
        await fixture.coordinator.cancel(transferID)
        await fixture.coordinator.cancel(transferID)
        let state = await fixture.coordinator.snapshots()
            .first(where: { $0.id == transferID })?.state
        XCTAssertEqual(state, .cancelled)
        let removed = await fixture.source.wasRemoved(transferID)
        XCTAssertTrue(removed)
        await fixture.coordinator.stop()
    }

    @MainActor
    func testCoordinatorRecoversSortsAndClearsPersistedTransfers() async throws {
        let fixture = FileTransferFixture()
        let completedIncoming = fixture.makeManifest(
            source: fixture.remote.id,
            destination: fixture.local.id,
            filename: "completed.txt"
        )
        let pausedIncoming = fixture.makeManifest(
            source: fixture.remote.id,
            destination: fixture.local.id,
            filename: "partial.txt"
        )
        let pausedOutgoing = fixture.makeManifest(
            source: fixture.local.id,
            destination: fixture.remote.id,
            filename: "outgoing.txt"
        )
        await fixture.store.setRecovered([
            RecoveredIncomingTransfer(
                manifest: completedIncoming,
                offsets: completedIncoming.entries.map {
                    TransferEntryOffset(entryID: $0.id, offset: $0.byteCount)
                },
                completedURLs: [URL(fileURLWithPath: "/tmp/completed.txt")]
            ),
            RecoveredIncomingTransfer(
                manifest: pausedIncoming,
                offsets: pausedIncoming.entries.map {
                    TransferEntryOffset(entryID: $0.id, offset: 1)
                }
            ),
        ])
        await fixture.source.setRecovered([PreparedOutgoingTransfer(manifest: pausedOutgoing)])

        try await fixture.coordinator.start(
            localDevice: fixture.local,
            workspace: fixture.workspace,
            key: Data(repeating: 9, count: 32)
        )
        let snapshots = await fixture.coordinator.snapshots()
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots.first?.isActive, true)
        XCTAssertEqual(
            snapshots.first(where: { $0.id == completedIncoming.transferID })?.state,
            .completed
        )
        let expiredRemovalCount = await fixture.store.removeExpiredCount()
        XCTAssertEqual(expiredRemovalCount, 1)

        await fixture.coordinator.clearCompleted()
        let removedCompleted = await fixture.store.wasRemoved(completedIncoming.transferID)
        let remainingCount = await fixture.coordinator.snapshots().count
        XCTAssertTrue(removedCompleted)
        XCTAssertEqual(remainingCount, 2)

        try await fixture.coordinator.start(
            localDevice: fixture.local,
            workspace: fixture.workspace,
            key: Data(repeating: 9, count: 32)
        )
        XCTAssertEqual(fixture.transport.startCount(), 2)
        XCTAssertGreaterThanOrEqual(fixture.transport.stopCount(), 1)
        XCTAssertEqual(fixture.transport.eventSubscriptionCount(), 1)
        XCTAssertEqual(fixture.pasteboard.eventSubscriptionCount, 1)
        await fixture.coordinator.stop()
    }

    @MainActor
    func testCoordinatorCoversDestinationSendRetryAndRemovalErrors() async throws {
        let fixture = FileTransferFixture()
        await assertThrows(.noDestination) {
            _ = try await fixture.coordinator.sendFiles([URL(fileURLWithPath: "/tmp/a")])
        }
        try await fixture.coordinator.start(
            localDevice: fixture.local,
            workspace: fixture.workspace,
            key: Data(repeating: 9, count: 32)
        )
        do {
            _ = try await fixture.coordinator.sendFiles([], to: fixture.remote.id)
            XCTFail("Expected empty manifest")
        } catch let error as FileTransferProtocolError {
            XCTAssertEqual(error, .emptyManifest)
        }
        await fixture.coordinator.setAutomaticDestination(fixture.local.id)
        await assertThrows(.noDestination) {
            _ = try await fixture.coordinator.sendFiles([URL(fileURLWithPath: "/tmp/a")])
        }
        await assertThrows(.peerUnavailable(fixture.remote.id)) {
            _ = try await fixture.coordinator.sendFiles(
                [URL(fileURLWithPath: "/tmp/a")],
                to: fixture.remote.id
            )
        }

        fixture.transport.emit(.connected(fixture.remote.id))
        let connected = await eventually {
            await fixture.coordinator.connectedDeviceIDs().contains(fixture.remote.id)
        }
        XCTAssertTrue(connected)
        fixture.transport.failNextSends()
        var failedTransferID: TransferID?
        do {
            _ = try await fixture.coordinator.sendFiles(
                [URL(fileURLWithPath: "/tmp/fails.txt")],
                to: fixture.remote.id
            )
            XCTFail("Expected failed offer")
        } catch let error as FileTransferCoordinatorError {
            XCTAssertEqual(error, .peerUnavailable(fixture.remote.id))
            failedTransferID = await fixture.coordinator.snapshots().first?.id
        }
        let transferID = try XCTUnwrap(failedTransferID)

        fixture.transport.emit(.disconnected(fixture.remote.id))
        let disconnected = await eventually {
            !(await fixture.coordinator.connectedDeviceIDs().contains(fixture.remote.id))
        }
        XCTAssertTrue(disconnected)
        await assertThrows(.peerUnavailable(fixture.remote.id)) {
            try await fixture.coordinator.retry(transferID)
        }
        let missingTransferID = TransferID()
        await assertThrows(.transferNotFound(missingTransferID)) {
            try await fixture.coordinator.retry(missingTransferID)
        }

        fixture.transport.emit(.connected(fixture.remote.id))
        let reconnected = await eventually {
            await fixture.coordinator.connectedDeviceIDs().contains(fixture.remote.id)
        }
        XCTAssertTrue(reconnected)
        try await fixture.coordinator.retry(transferID)
        await assertThrows(.invalidState(.awaitingAcceptance)) {
            try await fixture.coordinator.retry(transferID)
        }

        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .verification(
                TransferVerification(
                    transferID: transferID,
                    accepted: false,
                    failureCode: .hashMismatch
                )
            ))
        ))
        let rejected = await eventually {
            await fixture.coordinator.snapshots()
                .first(where: { $0.id == transferID })?.failureCode == .hashMismatch
        }
        XCTAssertTrue(rejected)
        await fixture.coordinator.remove(TransferID())
        await fixture.coordinator.remove(transferID)
        let sourceRemoved = await fixture.source.wasRemoved(transferID)
        let stillPresent = await fixture.coordinator.snapshots().contains { $0.id == transferID }
        XCTAssertTrue(sourceRemoved)
        XCTAssertFalse(stillPresent)
        await fixture.coordinator.stop()
    }

    @MainActor
    func testPasteboardSelectionWaitsForRemoteFocusBeforeOffering() async throws {
        let fixture = FileTransferFixture()
        try await fixture.startAndConnect()

        fixture.pasteboard.emit(PasteboardFileSelection(
            changeCount: 1,
            urls: [URL(fileURLWithPath: "/tmp/copied-before-focus.txt")]
        ))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(fixture.transport.messages().contains {
            if case .offer = $0.message { return true }
            return false
        })

        await fixture.coordinator.setAutomaticDestination(fixture.remote.id)

        var transferIDs = Set<TransferID>()
        for copyNumber in 1...3 {
            if copyNumber > 1 {
                fixture.pasteboard.emit(PasteboardFileSelection(
                    changeCount: copyNumber,
                    urls: [URL(fileURLWithPath: "/tmp/copied-before-focus.txt")]
                ))
            }

            let offered = await eventually {
                fixture.transport.messages().compactMap { envelope -> TransferOffer? in
                    guard case let .offer(offer) = envelope.message else { return nil }
                    return offer
                }.count == copyNumber
            }
            XCTAssertTrue(offered, "Copy \(copyNumber) should create a new file offer")

            let offer = try XCTUnwrap(fixture.transport.messages().compactMap { envelope -> TransferOffer? in
                guard case let .offer(value) = envelope.message else { return nil }
                return value
            }.last)
            XCTAssertEqual(offer.manifest.entries.first?.filename, "copied-before-focus.txt")
            XCTAssertTrue(
                transferIDs.insert(offer.manifest.transferID).inserted,
                "Copy \(copyNumber) should use a distinct transfer ID"
            )

            fixture.transport.emit(.message(
                fixture.remote.id,
                fixture.envelope(from: fixture.remote.id, message: .resumeState(
                    TransferResumeState(
                        transferID: offer.manifest.transferID,
                        offsets: [],
                        completed: true
                    )
                ))
            ))
            let completed = await eventually {
                await fixture.coordinator.snapshots()
                    .first(where: { $0.id == offer.manifest.transferID })?.state == .completed
            }
            XCTAssertTrue(completed, "Copy \(copyNumber) should complete before the next copy")
        }
        await fixture.coordinator.stop()
    }

    @MainActor
    func testCoordinatorHandlesResumeCancellationFailureAndAutomaticPasteboardOffer() async throws {
        let fixture = FileTransferFixture()
        try await fixture.startAndConnect()
        await fixture.coordinator.setAutomaticDestination(fixture.remote.id)
        fixture.pasteboard.emit(PasteboardFileSelection(
            changeCount: 1,
            urls: [URL(fileURLWithPath: "/tmp/pasteboard.txt")]
        ))
        fixture.pasteboard.emit(PasteboardFileSelection(
            changeCount: 1,
            urls: [URL(fileURLWithPath: "/tmp/duplicate.txt")]
        ))
        let offered = await eventually {
            fixture.transport.messages().filter {
                if case .offer = $0.message { return true }
                return false
            }.count == 1
        }
        XCTAssertTrue(offered)
        let optionalOutgoing = await fixture.coordinator.snapshots().first
        let outgoing = try XCTUnwrap(optionalOutgoing)

        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .resumeState(
                TransferResumeState(
                    transferID: outgoing.id,
                    offsets: [],
                    completed: true
                )
            ))
        ))
        let outgoingCompleted = await eventually {
            await fixture.coordinator.snapshots()
                .first(where: { $0.id == outgoing.id })?.state == .completed
        }
        XCTAssertTrue(outgoingCompleted)

        let incoming = fixture.makeManifest(
            source: fixture.remote.id,
            destination: fixture.local.id,
            filename: "incoming.txt"
        )
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .offer(
                TransferOffer(manifest: incoming)
            ))
        ))
        let incomingStarted = await eventually {
            await fixture.coordinator.snapshots()
                .first(where: { $0.id == incoming.transferID })?.state == .transferring
        }
        XCTAssertTrue(incomingStarted)
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .resumeQuery(
                TransferResumeQuery(transferID: incoming.transferID)
            ))
        ))
        let resumeStateSent = await eventually {
            fixture.transport.messages().contains {
                if case let .resumeState(value) = $0.message {
                    return value.transferID == incoming.transferID
                }
                return false
            }
        }
        XCTAssertTrue(resumeStateSent)
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .cancellation(
                TransferCancellation(transferID: incoming.transferID, reason: .cancelled)
            ))
        ))
        let incomingCancelled = await eventually {
            await fixture.coordinator.snapshots()
                .first(where: { $0.id == incoming.transferID })?.state == .cancelled
        }
        XCTAssertTrue(incomingCancelled)

        fixture.transport.emit(.failure(fixture.remote.id, .timedOut))
        fixture.transport.emit(.failure(nil, .unknown))
        await fixture.coordinator.stop()
    }

    @MainActor
    func testCoordinatorRejectsEveryUnknownOrMalformedPeerMessage() async throws {
        let fixture = FileTransferFixture()
        try await fixture.startAndConnect()
        let transferID = TransferID()
        let entryID = TransferEntryID()
        let unknownMessages: [FileTransferMessage] = [
            .request(TransferRequest(transferID: transferID, offsets: [])),
            .chunk(TransferChunk(
                transferID: transferID,
                entryID: entryID,
                offset: 0,
                data: Data([1])
            )),
            .acknowledgement(TransferAcknowledgement(
                transferID: transferID,
                entryID: entryID,
                verifiedOffset: 1
            )),
            .entryComplete(TransferEntryCompletion(transferID: transferID, entryID: entryID)),
            .transferComplete(TransferCompletion(transferID: transferID)),
            .resumeQuery(TransferResumeQuery(transferID: transferID)),
            .resumeState(TransferResumeState(
                transferID: transferID,
                offsets: [
                    TransferEntryOffset(entryID: entryID, offset: 1),
                    TransferEntryOffset(entryID: entryID, offset: 1),
                ],
                completed: false
            )),
        ]
        for message in unknownMessages {
            fixture.transport.emit(.message(
                fixture.remote.id,
                fixture.envelope(from: fixture.remote.id, message: message)
            ))
        }

        let wrongWorkspace = FileTransferEnvelope(
            workspaceID: WorkspaceID(),
            senderDeviceID: fixture.remote.id,
            message: .cancellation(TransferCancellation(transferID: transferID))
        )
        fixture.transport.emit(.message(fixture.remote.id, wrongWorkspace))
        let failuresSent = await eventually {
            fixture.transport.messages().filter {
                if case .failure = $0.message { return true }
                return false
            }.count >= unknownMessages.count + 1
        }
        XCTAssertTrue(failuresSent)

        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .verification(
                TransferVerification(transferID: transferID, accepted: true)
            ))
        ))
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .cancellation(
                TransferCancellation(transferID: transferID)
            ))
        ))
        fixture.transport.emit(.message(
            fixture.remote.id,
            fixture.envelope(from: fixture.remote.id, message: .failure(
                TransferFailure(transferID: transferID, code: .timedOut)
            ))
        ))
        await fixture.coordinator.stop()
    }

    @MainActor
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

    @MainActor
    private func assertThrows(
        _ expected: FileTransferCoordinatorError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as FileTransferCoordinatorError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

@MainActor
private final class FileTransferFixture {
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

    func startAndConnect() async throws {
        try await coordinator.start(
            localDevice: local,
            workspace: workspace,
            key: Data(repeating: 9, count: 32)
        )
        transport.emit(.connected(remote.id))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            let connected = await coordinator.connectedDeviceIDs()
            if connected.contains(remote.id) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Transport did not connect")
    }

    func envelope(from sender: DeviceID, message: FileTransferMessage) -> FileTransferEnvelope {
        FileTransferEnvelope(
            workspaceID: workspace.id,
            senderDeviceID: sender,
            message: message
        )
    }

    func makeManifest(
        source: DeviceID,
        destination: DeviceID,
        filename: String
    ) -> TransferManifest {
        TransferManifest(
            workspaceID: workspace.id,
            sourceDeviceID: source,
            destinationDeviceID: destination,
            entries: [TransferManifestEntry(
                filename: filename,
                byteCount: 4,
                sha256: Data(repeating: 1, count: 32)
            )]
        )
    }
}

private enum FileTransferSpyError: Error { case failed }

private final class FileTransferTransportSpy: FileTransferTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<FileTransferTransportEvent>
    private let continuation: AsyncStream<FileTransferTransportEvent>.Continuation
    private var sent: [FileTransferEnvelope] = []
    private var blockChunkSends = false
    private var chunkSendAttempts = 0
    private var activeChunkSends = 0
    private var cancelledChunkSends = 0
    private var sendFailuresRemaining = 0
    private var starts = 0
    private var stops = 0
    private var eventSubscriptions = 0

    init() {
        var captured: AsyncStream<FileTransferTransportEvent>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {
        lock.testWithLock { starts += 1 }
    }
    func stop() async { lock.testWithLock { stops += 1 } }
    func events() -> AsyncStream<FileTransferTransportEvent> {
        lock.testWithLock { eventSubscriptions += 1 }
        return stream
    }

    func send(_ envelope: FileTransferEnvelope, to deviceID: DeviceID) async throws {
        let shouldFailImmediately = lock.testWithLock { () -> Bool in
            guard sendFailuresRemaining > 0 else { return false }
            sendFailuresRemaining -= 1
            return true
        }
        if shouldFailImmediately { throw FileTransferSpyError.failed }
        let shouldBlock = lock.testWithLock { () -> Bool in
            guard blockChunkSends, case .chunk = envelope.message else { return false }
            chunkSendAttempts += 1
            activeChunkSends += 1
            return true
        }
        if shouldBlock {
            defer { lock.testWithLock { activeChunkSends -= 1 } }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                lock.testWithLock { cancelledChunkSends += 1 }
                throw error
            }
        }
        lock.testWithLock { sent.append(envelope) }
    }

    func emit(_ event: FileTransferTransportEvent) {
        continuation.yield(event)
    }

    func messages() -> [FileTransferEnvelope] {
        lock.testWithLock { sent }
    }

    func setChunkSendsBlocked(_ blocked: Bool) {
        lock.testWithLock { blockChunkSends = blocked }
    }

    func chunkSendAttemptCount() -> Int { lock.testWithLock { chunkSendAttempts } }
    func activeChunkSendCount() -> Int { lock.testWithLock { activeChunkSends } }
    func cancelledChunkSendCount() -> Int { lock.testWithLock { cancelledChunkSends } }
    func failNextSends(_ count: Int = 1) { lock.testWithLock { sendFailuresRemaining = count } }
    func startCount() -> Int { lock.testWithLock { starts } }
    func stopCount() -> Int { lock.testWithLock { stops } }
    func eventSubscriptionCount() -> Int { lock.testWithLock { eventSubscriptions } }
}

private actor FileSourceProviderSpy: FileSourceProvider {
    private var manifests: [TransferID: TransferManifest] = [:]
    private var payloads: [TransferID: Data] = [:]
    private var removed = Set<TransferID>()
    private var recovered: [PreparedOutgoingTransfer] = []

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
        guard let data = payloads[transferID] else {
            throw FileTransferCoordinatorError.sourceChanged
        }
        let start = Int(offset)
        guard start <= data.count else { throw FileTransferCoordinatorError.sourceChanged }
        return data.subdata(in: start..<min(start + maximumLength, data.count))
    }

    func recoverOutgoingTransfers(limits: FileTransferLimits) async throws -> [PreparedOutgoingTransfer] {
        recovered
    }

    func removeOutgoingTransfer(_ transferID: TransferID) async {
        removed.insert(transferID)
    }

    func manifest(_ transferID: TransferID) -> TransferManifest? { manifests[transferID] }
    func wasRemoved(_ transferID: TransferID) -> Bool { removed.contains(transferID) }
    func setRecovered(_ values: [PreparedOutgoingTransfer]) { recovered = values }
}

private actor TransferStoreSpy: TransferStore {
    private var manifests: [TransferID: TransferManifest] = [:]
    private var offsets: [TransferID: [TransferEntryID: UInt64]] = [:]
    private var finalized: [TransferID: [URL]] = [:]
    private var writes = 0
    private var recovered: [RecoveredIncomingTransfer] = []
    private var removed = Set<TransferID>()
    private var expiredRemovalCount = 0

    func prepareIncoming(manifest: TransferManifest, limits: FileTransferLimits) async throws {
        manifests[manifest.transferID] = manifest
        offsets[manifest.transferID] = Dictionary(
            uniqueKeysWithValues: manifest.entries.map { ($0.id, 0) }
        )
    }

    func write(_ chunk: TransferChunk, limits: FileTransferLimits) async throws -> UInt64 {
        writes += 1
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
        if !(finalized[transferID] ?? []).contains(url) {
            finalized[transferID, default: []].append(url)
        }
        return url
    }

    func finalizeTransfer(_ transferID: TransferID) async throws -> [URL] {
        finalized[transferID] ?? []
    }

    func completedURLs(for transferID: TransferID) async throws -> [URL] {
        finalized[transferID] ?? []
    }

    func recoverIncomingTransfers(limits: FileTransferLimits) async throws -> [RecoveredIncomingTransfer] {
        recovered
    }
    func cancel(_ transferID: TransferID) async { manifests.removeValue(forKey: transferID) }
    func remove(_ transferID: TransferID) async {
        manifests.removeValue(forKey: transferID)
        removed.insert(transferID)
    }
    func removeExpired(now: Date, limits: FileTransferLimits) async { expiredRemovalCount += 1 }

    func offset(transferID: TransferID, entryID: TransferEntryID) -> UInt64 {
        offsets[transferID]?[entryID] ?? 0
    }

    func writeCount() -> Int { writes }
    func setRecovered(_ values: [RecoveredIncomingTransfer]) { recovered = values }
    func wasRemoved(_ transferID: TransferID) -> Bool { removed.contains(transferID) }
    func removeExpiredCount() -> Int { expiredRemovalCount }
}

@MainActor
private final class FilePasteboardSpy: FilePasteboard {
    private let stream: AsyncStream<PasteboardFileSelection>
    private let continuation: AsyncStream<PasteboardFileSelection>.Continuation
    private(set) var publishedURLs: [URL] = []
    private(set) var publishedTransferID: TransferID?
    private(set) var eventSubscriptionCount = 0
    private(set) var publicationAttempts = 0
    var publicationError: Error?

    init() {
        var captured: AsyncStream<PasteboardFileSelection>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    func events() -> AsyncStream<PasteboardFileSelection> {
        eventSubscriptionCount += 1
        return stream
    }

    func publishFiles(_ urls: [URL], transferID: TransferID) {
        publishedURLs = urls
        publishedTransferID = transferID
    }

    func publishFilesChecked(_ urls: [URL], transferID: TransferID) throws {
        publicationAttempts += 1
        if let publicationError { throw publicationError }
        publishFiles(urls, transferID: transferID)
    }

    func emit(_ selection: PasteboardFileSelection) { continuation.yield(selection) }
}

@MainActor
private final class LegacyFilePasteboardSpy: FilePasteboard {
    private let stream = AsyncStream<PasteboardFileSelection> { $0.finish() }
    private(set) var publishedURLs: [URL] = []
    private(set) var publishedTransferID: TransferID?

    func events() -> AsyncStream<PasteboardFileSelection> { stream }

    func publishFiles(_ urls: [URL], transferID: TransferID) {
        publishedURLs = urls
        publishedTransferID = transferID
    }
}

private extension NSLock {
    func testWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
