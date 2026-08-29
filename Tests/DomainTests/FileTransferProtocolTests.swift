import Foundation
import XCTest
@testable import UniSpaceDomain

final class FileTransferProtocolTests: XCTestCase {
    func testManifestValidatesRegularFilesAndComputesTotal() throws {
        let manifest = makeManifest(entries: [
            makeEntry(filename: "one.txt", byteCount: 10),
            makeEntry(filename: "two.pdf", byteCount: 25)
        ])

        XCTAssertNoThrow(try manifest.validated())
        XCTAssertEqual(manifest.totalByteCount, 35)
        XCTAssertEqual(manifest.displayName, "2 files")
    }

    func testManifestRejectsUnsafeAndDuplicateNames() {
        let unsafeNames = [
            "",
            ".",
            "..",
            "../secret",
            "folder/file",
            "folder\\file",
            "bad\u{0000}name",
            "bad:name",
            "bad?name",
            "bad*name",
            "bad\"name",
            "bad<name",
            "bad>name",
            "bad|name",
            "trailing.",
            "trailing ",
            "CON.txt",
            "nul",
            "COM1.log",
            "LPT9",
        ]
        for name in unsafeNames {
            XCTAssertThrowsError(try makeManifest(entries: [
                makeEntry(filename: name)
            ]).validated(), "Expected \(name.debugDescription) to fail")
        }

        let duplicate = makeManifest(entries: [
            makeEntry(filename: "Résumé.txt"),
            makeEntry(filename: "resume.TXT")
        ])
        XCTAssertThrowsError(try duplicate.validated()) { error in
            guard case FileTransferProtocolError.duplicateFilename = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testManifestRejectsDuplicateIdentifiersAndInvalidDigest() {
        let id = TransferEntryID()
        let duplicateID = makeManifest(entries: [
            makeEntry(id: id, filename: "first"),
            makeEntry(id: id, filename: "second")
        ])
        XCTAssertThrowsError(try duplicateID.validated())

        let invalidDigest = makeManifest(entries: [
            TransferManifestEntry(filename: "file", byteCount: 1, sha256: Data([1]))
        ])
        XCTAssertThrowsError(try invalidDigest.validated())
    }

    func testManifestEnforcesEntryAndTransferLimits() {
        let limits = FileTransferLimits(
            maximumManifestEntries: 1,
            maximumFilenameBytes: 255,
            defaultChunkSize: 4,
            maximumChunkSize: 8,
            maximumTransferBytes: 10,
            acknowledgementIntervalBytes: 4
        )
        XCTAssertThrowsError(try makeManifest(entries: [
            makeEntry(filename: "a", byteCount: 1),
            makeEntry(filename: "b", byteCount: 1)
        ]).validated(limits: limits))
        XCTAssertThrowsError(try makeManifest(entries: [
            makeEntry(filename: "large", byteCount: 11)
        ]).validated(limits: limits))
    }

    func testChunkValidationChecksEntryOffsetAndBounds() throws {
        let entry = makeEntry(filename: "file", byteCount: 8)
        let manifest = makeManifest(entries: [entry])
        let valid = TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: 2,
            data: Data([1, 2, 3])
        )
        XCTAssertNoThrow(try valid.validated(against: manifest))

        XCTAssertThrowsError(try TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: 7,
            data: Data([1, 2])
        ).validated(against: manifest))
        XCTAssertThrowsError(try TransferChunk(
            transferID: manifest.transferID,
            entryID: TransferEntryID(),
            offset: 0,
            data: Data([1])
        ).validated(against: manifest))
        XCTAssertThrowsError(try TransferChunk(
            transferID: manifest.transferID,
            entryID: entry.id,
            offset: 0,
            data: Data()
        ).validated(against: manifest))
    }

    func testEnvelopeValidationIsWorkspaceAndPeerBound() throws {
        let workspace = WorkspaceID()
        let sender = DeviceID()
        let envelope = FileTransferEnvelope(
            workspaceID: workspace,
            senderDeviceID: sender,
            message: .cancellation(TransferCancellation(transferID: TransferID()))
        )
        XCTAssertNoThrow(try envelope.validated(
            workspaceID: workspace,
            senderDeviceID: sender
        ))
        XCTAssertThrowsError(try envelope.validated(
            workspaceID: WorkspaceID(),
            senderDeviceID: sender
        ))
        XCTAssertThrowsError(try envelope.validated(
            workspaceID: workspace,
            senderDeviceID: DeviceID()
        ))

        let future = FileTransferEnvelope(
            version: 99,
            workspaceID: workspace,
            senderDeviceID: sender,
            message: envelope.message
        )
        XCTAssertThrowsError(try future.validated(
            workspaceID: workspace,
            senderDeviceID: sender
        ))
    }

    func testTransferStateMachineAllowsOnlyIntentionalTransitions() {
        XCTAssertTrue(FileTransferState.offered.canTransition(to: .awaitingAcceptance))
        XCTAssertTrue(FileTransferState.transferring.canTransition(to: .paused))
        XCTAssertTrue(FileTransferState.paused.canTransition(to: .transferring))
        XCTAssertTrue(FileTransferState.verifying.canTransition(to: .completed))
        XCTAssertFalse(FileTransferState.completed.canTransition(to: .transferring))
        XCTAssertFalse(FileTransferState.cancelled.canTransition(to: .preparing))
        XCTAssertFalse(FileTransferState.offered.canTransition(to: .completed))
    }

    func testMessagesRoundTripThroughCodable() throws {
        let manifest = makeManifest(entries: [makeEntry(filename: "file", byteCount: 3)])
        let entry = manifest.entries[0]
        let messages: [FileTransferMessage] = [
            .offer(TransferOffer(manifest: manifest)),
            .request(TransferRequest(
                transferID: manifest.transferID,
                offsets: [TransferEntryOffset(entryID: entry.id, offset: 0)]
            )),
            .chunk(TransferChunk(
                transferID: manifest.transferID,
                entryID: entry.id,
                offset: 0,
                data: Data([1, 2, 3])
            )),
            .acknowledgement(TransferAcknowledgement(
                transferID: manifest.transferID,
                entryID: entry.id,
                verifiedOffset: 3
            )),
            .entryComplete(TransferEntryCompletion(
                transferID: manifest.transferID,
                entryID: entry.id
            )),
            .transferComplete(TransferCompletion(transferID: manifest.transferID)),
            .verification(TransferVerification(transferID: manifest.transferID, accepted: true)),
            .cancellation(TransferCancellation(transferID: manifest.transferID)),
            .resumeQuery(TransferResumeQuery(transferID: manifest.transferID)),
            .resumeState(TransferResumeState(
                transferID: manifest.transferID,
                offsets: [],
                completed: false
            )),
            .failure(TransferFailure(transferID: manifest.transferID, code: .hashMismatch))
        ]
        for message in messages {
            let data = try JSONEncoder().encode(message)
            XCTAssertEqual(try JSONDecoder().decode(FileTransferMessage.self, from: data), message)
        }
    }

    func testProtocolIdentifiersAndErrorsExposeStableDiagnosticValues() {
        let first = TransferEntryID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let second = TransferEntryID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        XCTAssertLessThan(first, second)

        let descriptions: [(FileTransferProtocolError, String)] = [
            (.unsupportedVersion(2), "Unsupported file-transfer protocol version 2."),
            (.emptyManifest, "The transfer does not contain any files."),
            (.tooManyEntries(2), "The transfer contains too many files."),
            (.transferTooLarge(2), "The transfer exceeds the configured size limit."),
            (.invalidFilename("x"), "A file has an invalid name."),
            (.duplicateEntry(first), "The transfer contains duplicate files."),
            (.duplicateFilename("x"), "The transfer contains duplicate files."),
            (.invalidDigest(first), "A file has an invalid integrity digest."),
            (.invalidFileSize(first), "A file has an invalid size."),
            (.invalidChunkSize(0), "A transfer chunk has an invalid size."),
            (.invalidOffset(entryID: first, offset: 1), "A transfer chunk has an invalid offset."),
            (.chunkExceedsEntry(entryID: first), "A transfer chunk has an invalid offset."),
            (.unknownEntry(first), "A transfer references an unknown file."),
            (.workspaceMismatch, "The transfer does not belong to this trusted workspace or peer."),
            (.peerMismatch, "The transfer does not belong to this trusted workspace or peer."),
            (.malformedEnvelope, "The transfer message is malformed."),
        ]
        for (error, description) in descriptions {
            XCTAssertEqual(error.errorDescription, description)
        }
    }

    private func makeManifest(entries: [TransferManifestEntry]) -> TransferManifest {
        TransferManifest(
            workspaceID: WorkspaceID(),
            sourceDeviceID: DeviceID(),
            destinationDeviceID: DeviceID(),
            entries: entries
        )
    }

    private func makeEntry(
        id: TransferEntryID = TransferEntryID(),
        filename: String,
        byteCount: UInt64 = 1
    ) -> TransferManifestEntry {
        TransferManifestEntry(
            id: id,
            filename: filename,
            byteCount: byteCount,
            sha256: Data(repeating: 7, count: 32)
        )
    }
}
