import Foundation
import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class FileTransferPortableInteropTests: XCTestCase {
    private let workspaceID = WorkspaceID(
        rawValue: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    )
    private let senderID = DeviceID(
        rawValue: UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")!
    )
    private let transferID = TransferID(
        rawValue: UUID(uuidString: "11223344-5566-7788-99AA-BBCCDDEEFF00")!
    )
    private let entryID = TransferEntryID(
        rawValue: UUID(uuidString: "22334455-6677-8899-AABB-CCDDEEFF0011")!
    )

    func testPortableCancellationMatchesSharedSwiftDotNetFixture() throws {
        let envelope = FileTransferEnvelope(
            workspaceID: workspaceID,
            senderDeviceID: senderID,
            message: .cancellation(TransferCancellation(transferID: transferID))
        )

        let encoded = try FileTransferFrameCodec.encode(envelope)
        XCTAssertEqual(
            encoded.hexString,
            "00010800112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f000000577b22726561736f6e223a2263616e63656c6c6564222c227472616e736665724944223a7b2272617756616c7565223a2231313232333334342d353536362d373738382d393941412d424243434444454546463030227d7d"
        )
        XCTAssertEqual(try FileTransferFrameCodec.decode(encoded), envelope)
    }

    func testPortableChunkMatchesSharedSwiftDotNetFixture() throws {
        let envelope = FileTransferEnvelope(
            workspaceID: workspaceID,
            senderDeviceID: senderID,
            message: .chunk(TransferChunk(
                transferID: transferID,
                entryID: entryID,
                offset: 0x0102_0304_0506_0708,
                data: Data([0xDE, 0xAD, 0xBE, 0xEF])
            ))
        )

        let encoded = try FileTransferFrameCodec.encode(envelope)
        XCTAssertEqual(
            encoded.hexString,
            "00010300112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f00000030112233445566778899aabbccddeeff002233445566778899aabbccddeeff0011010203040506070800000004deadbeef"
        )
        XCTAssertEqual(try FileTransferFrameCodec.decode(encoded), envelope)
    }

    func testPortableCodecRejectsUnknownKindAndLengthMismatch() throws {
        let valid = try FileTransferFrameCodec.encode(FileTransferEnvelope(
            workspaceID: workspaceID,
            senderDeviceID: senderID,
            message: .resumeQuery(TransferResumeQuery(transferID: transferID))
        ))

        var unknownKind = valid
        unknownKind[2] = 0xFF
        XCTAssertThrowsError(try FileTransferFrameCodec.decode(unknownKind))

        var badLength = valid
        badLength[FileTransferFrameCodec.headerSize - 1] &+= 1
        XCTAssertThrowsError(try FileTransferFrameCodec.decode(badLength))
    }

    func testPortableCodecRoundTripsEveryMetadataMessageAndRejectsMalformedPayloads() throws {
        let entry = TransferManifestEntry(
            id: entryID,
            filename: "file.txt",
            byteCount: 4,
            sha256: Data(repeating: 1, count: 32)
        )
        let manifest = TransferManifest(
            transferID: transferID,
            workspaceID: workspaceID,
            sourceDeviceID: senderID,
            destinationDeviceID: DeviceID(),
            entries: [entry],
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let messages: [FileTransferMessage] = [
            .offer(TransferOffer(manifest: manifest)),
            .request(TransferRequest(
                transferID: transferID,
                offsets: [TransferEntryOffset(entryID: entryID, offset: 1)]
            )),
            .acknowledgement(TransferAcknowledgement(
                transferID: transferID,
                entryID: entryID,
                verifiedOffset: 2
            )),
            .entryComplete(TransferEntryCompletion(transferID: transferID, entryID: entryID)),
            .transferComplete(TransferCompletion(transferID: transferID)),
            .verification(TransferVerification(transferID: transferID, accepted: true)),
            .resumeState(TransferResumeState(
                transferID: transferID,
                offsets: [TransferEntryOffset(entryID: entryID, offset: 3)],
                completed: false
            )),
            .failure(TransferFailure(transferID: transferID, code: .sourceChanged)),
        ]
        for message in messages {
            let envelope = FileTransferEnvelope(
                workspaceID: workspaceID,
                senderDeviceID: senderID,
                message: message
            )
            XCTAssertEqual(try FileTransferFrameCodec.decode(
                FileTransferFrameCodec.encode(envelope)
            ), envelope)
        }

        let future = FileTransferEnvelope(
            version: 2,
            workspaceID: workspaceID,
            senderDeviceID: senderID,
            message: .resumeQuery(TransferResumeQuery(transferID: transferID))
        )
        XCTAssertThrowsError(try FileTransferFrameCodec.encode(future))

        var unsupportedVersion = try FileTransferFrameCodec.encode(FileTransferEnvelope(
            workspaceID: workspaceID,
            senderDeviceID: senderID,
            message: .resumeQuery(TransferResumeQuery(transferID: transferID))
        ))
        unsupportedVersion[0] = 0
        unsupportedVersion[1] = 2
        XCTAssertThrowsError(try FileTransferFrameCodec.decode(unsupportedVersion))

        var malformedJSON = try FileTransferFrameCodec.encode(FileTransferEnvelope(
            workspaceID: workspaceID,
            senderDeviceID: senderID,
            message: .failure(TransferFailure(transferID: transferID, code: .unknown))
        ))
        malformedJSON.replaceSubrange(
            FileTransferFrameCodec.headerSize..<malformedJSON.count,
            with: Data(repeating: 0, count: malformedJSON.count - FileTransferFrameCodec.headerSize)
        )
        XCTAssertThrowsError(try FileTransferFrameCodec.decode(malformedJSON))

        let oversizedChunk = FileTransferEnvelope(
            workspaceID: workspaceID,
            senderDeviceID: senderID,
            message: .chunk(TransferChunk(
                transferID: transferID,
                entryID: entryID,
                offset: 0,
                data: Data(repeating: 0, count: FileTransferLimits.default.maximumChunkSize + 1)
            ))
        )
        XCTAssertThrowsError(try FileTransferFrameCodec.encode(oversizedChunk))

        var emptyChunk = try FileTransferFrameCodec.encode(FileTransferEnvelope(
            workspaceID: workspaceID,
            senderDeviceID: senderID,
            message: .chunk(TransferChunk(
                transferID: transferID,
                entryID: entryID,
                offset: 0,
                data: Data([1])
            ))
        ))
        let countOffset = FileTransferFrameCodec.headerSize + 16 + 16 + 8
        emptyChunk[countOffset..<(countOffset + 4)] = Data(repeating: 0, count: 4)
        XCTAssertThrowsError(try FileTransferFrameCodec.decode(emptyChunk))
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
