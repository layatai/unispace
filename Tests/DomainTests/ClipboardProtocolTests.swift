import Foundation
import XCTest
@testable import UniSpaceDomain

final class ClipboardProtocolTests: XCTestCase {
    func testNormalizesTextAndURLRepresentationsDeterministically() throws {
        let values = [
            ClipboardRepresentation(
                kind: .url,
                value: " https://example.com/path?q=1 \n"
            ),
            ClipboardRepresentation(
                kind: .plainText,
                value: "first\r\nsecond\rthird"
            )
        ]

        let normalized = try ClipboardPayload.normalizedRepresentations(values)

        XCTAssertEqual(normalized.map(\.kind), [.plainText, .url])
        XCTAssertEqual(normalized[0].value, "first\nsecond\nthird")
        XCTAssertEqual(normalized[1].value, "https://example.com/path?q=1")
    }

    func testRejectsFileURLsDuplicateKindsAndOversizedRepresentations() throws {
        XCTAssertThrowsError(try ClipboardRepresentation(
            kind: .url,
            value: "file:///tmp/private.txt"
        ).validated())

        let duplicate = ClipboardPayload(
            originDeviceID: DeviceID(),
            revision: 1,
            contentHash: Data(repeating: 1, count: 32),
            representations: [
                ClipboardRepresentation(kind: .plainText, value: "one"),
                ClipboardRepresentation(kind: .plainText, value: "two")
            ]
        )
        XCTAssertThrowsError(try duplicate.validated()) { error in
            XCTAssertEqual(
                error as? ClipboardProtocolError,
                .duplicateRepresentation(.plainText)
            )
        }

        let smallLimits = ClipboardLimits(
            maximumRepresentations: 2,
            maximumRepresentationBytes: 4,
            maximumPayloadBytes: 8,
            recentPayloadCapacity: 4,
            recentPayloadLifetime: 10
        )
        XCTAssertThrowsError(try ClipboardRepresentation(
            kind: .plainText,
            value: "12345"
        ).validated(limits: smallLimits))
    }

    func testPayloadRequiresSortedRepresentationsAndValidMetadata() throws {
        let origin = DeviceID()
        let unsorted = ClipboardPayload(
            originDeviceID: origin,
            revision: 1,
            contentHash: Data(repeating: 2, count: 32),
            representations: [
                ClipboardRepresentation(kind: .url, value: "https://example.com"),
                ClipboardRepresentation(kind: .plainText, value: "Example")
            ]
        )
        XCTAssertThrowsError(try unsorted.validated())

        let zeroRevision = ClipboardPayload(
            originDeviceID: origin,
            revision: 0,
            contentHash: Data(repeating: 2, count: 32),
            representations: [
                ClipboardRepresentation(kind: .plainText, value: "Example")
            ]
        )
        XCTAssertThrowsError(try zeroRevision.validated())

        let invalidDigest = ClipboardPayload(
            originDeviceID: origin,
            revision: 1,
            contentHash: Data(repeating: 2, count: 31),
            representations: [
                ClipboardRepresentation(kind: .plainText, value: "Example")
            ]
        )
        XCTAssertThrowsError(try invalidDigest.validated())
    }

    func testEnvelopeValidatesWorkspaceSenderAndOrigin() throws {
        let workspaceID = WorkspaceID()
        let senderID = DeviceID()
        let representations = [
            ClipboardRepresentation(kind: .plainText, value: "Hello")
        ]
        let payload = ClipboardPayload(
            originDeviceID: senderID,
            revision: 42,
            contentHash: Data(repeating: 3, count: 32),
            representations: representations
        )
        let envelope = ClipboardEnvelope(
            workspaceID: workspaceID,
            senderDeviceID: senderID,
            payload: payload
        )

        XCTAssertNoThrow(try envelope.validated(
            workspaceID: workspaceID,
            senderDeviceID: senderID
        ))
        XCTAssertThrowsError(try envelope.validated(
            workspaceID: WorkspaceID(),
            senderDeviceID: senderID
        ))
        XCTAssertThrowsError(try envelope.validated(
            workspaceID: workspaceID,
            senderDeviceID: DeviceID()
        ))

        let wrongOrigin = ClipboardEnvelope(
            workspaceID: workspaceID,
            senderDeviceID: senderID,
            payload: ClipboardPayload(
                originDeviceID: DeviceID(),
                revision: 43,
                contentHash: Data(repeating: 4, count: 32),
                representations: representations
            )
        )
        XCTAssertThrowsError(try wrongOrigin.validated(
            workspaceID: workspaceID,
            senderDeviceID: senderID
        ))
    }

    func testCanonicalContentDataIsIndependentOfInputOrdering() {
        let text = ClipboardRepresentation(kind: .plainText, value: "Example")
        let url = ClipboardRepresentation(kind: .url, value: "https://example.com")

        XCTAssertEqual(
            ClipboardPayload.canonicalContentData(for: [text, url]),
            ClipboardPayload.canonicalContentData(for: [url, text])
        )
        XCTAssertNotEqual(
            ClipboardPayload.canonicalContentData(for: [text]),
            ClipboardPayload.canonicalContentData(for: [url])
        )
    }

    func testClipboardProtocolCoversPortableLimitsAccessorsAndDescriptions() throws {
        let firstID = ClipboardPayloadID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let secondID = ClipboardPayloadID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        XCTAssertLessThan(firstID, secondID)

        let descriptions: [(ClipboardProtocolError, String)] = [
            (.unsupportedVersion(2), "Unsupported clipboard protocol version 2."),
            (.emptyPayload, "The clipboard does not contain supported text or link data."),
            (.tooManyRepresentations(3), "The clipboard contains too many representations."),
            (.duplicateRepresentation(.plainText), "The clipboard contains duplicate representations."),
            (.invalidRepresentation(.plainText), "The clipboard contains an invalid representation."),
            (.representationTooLarge(.plainText), "The clipboard content exceeds the configured size limit."),
            (.payloadTooLarge(9), "The clipboard content exceeds the configured size limit."),
            (.invalidRevision, "The clipboard update has an invalid revision."),
            (.invalidDigest, "The clipboard update failed its integrity check."),
            (.originMismatch, "The clipboard update came from an unexpected device."),
            (.peerMismatch, "The clipboard update came from an unexpected device."),
            (.workspaceMismatch, "The clipboard update belongs to a different workspace."),
            (.malformedEnvelope, "The clipboard update is malformed."),
        ]
        for (error, description) in descriptions {
            XCTAssertEqual(error.errorDescription, description)
        }

        XCTAssertThrowsError(try ClipboardRepresentation(
            kind: .plainText,
            value: "bad\u{0000}value"
        ).validated())

        let origin = DeviceID()
        let text = ClipboardRepresentation(kind: .plainText, value: "text")
        let url = ClipboardRepresentation(kind: .url, value: "https://example.com")
        let payload = ClipboardPayload(
            payloadID: firstID,
            originDeviceID: origin,
            revision: 1,
            contentHash: Data(repeating: 1, count: 32),
            representations: [text, url]
        )
        XCTAssertEqual(payload.plainText, "text")
        XCTAssertEqual(payload.url, "https://example.com")

        let tightLimits = ClipboardLimits(
            maximumRepresentations: 1,
            maximumRepresentationBytes: 10,
            maximumPayloadBytes: 3,
            recentPayloadCapacity: 1,
            recentPayloadLifetime: 1
        )
        XCTAssertThrowsError(try payload.validated(limits: tightLimits))
        let tooLarge = ClipboardPayload(
            originDeviceID: origin,
            revision: 1,
            contentHash: Data(repeating: 1, count: 32),
            representations: [text]
        )
        XCTAssertThrowsError(try tooLarge.validated(limits: tightLimits))

        let future = ClipboardEnvelope(
            version: 2,
            workspaceID: WorkspaceID(),
            senderDeviceID: origin,
            payload: payload
        )
        XCTAssertThrowsError(try future.validated(
            workspaceID: future.workspaceID,
            senderDeviceID: origin
        ))
    }
}
