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
}
