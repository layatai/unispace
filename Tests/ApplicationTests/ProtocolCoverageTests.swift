import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class ProtocolCoverageTests: XCTestCase {
    func testEveryControlMessageRoundTripsThroughWireCodec() throws {
        let deviceID = DeviceID()
        let workspaceID = WorkspaceID()
        let sessionID = SessionID()
        let displayID = DisplayID()
        let epoch = ControllerEpoch(generation: 7, controllerID: deviceID)
        let display = DisplayDescriptor(
            id: displayID,
            deviceID: deviceID,
            name: "Display",
            frame: .init(x: 0, y: 0, width: 1440, height: 900),
            scaleFactor: 2,
            isMain: true
        )
        let device = DeviceDescriptor(
            id: deviceID,
            name: "Mac",
            displays: [display],
            capabilities: [.publicTrackpadGestures]
        )
        let workspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Workspace",
            localDeviceID: deviceID,
            devices: [device]
        )
        let messages: [ControlMessage] = [
            .hello(device),
            .workspace(workspace),
            .controllerClaim(epoch),
            .activate(.init(
                sessionID: sessionID,
                epoch: epoch,
                targetDisplayID: displayID,
                entryEdge: .left,
                normalizedPosition: 0.25
            )),
            .deactivate(sessionID),
            .heartbeat(sessionID: sessionID, timestampNanos: 123),
            .boundaryCrossed(
                sessionID: sessionID,
                displayID: displayID,
                edge: .right,
                normalizedPosition: 0.75
            ),
            .releaseAll(sessionID),
            .rotateWorkspaceKey(Data([1, 2, 3, 4]))
        ]

        for message in messages {
            let envelope = ControlEnvelope(message: message)
            let encoded = try WireFrameCodec.encodeControl(envelope)
            let (kind, payload) = try WireFrameCodec.decode(encoded)
            XCTAssertEqual(kind, .controlJSON)
            XCTAssertEqual(try WireFrameCodec.decodeControl(payload), envelope)
        }
    }

    func testEveryInputEventRoundTripsThroughReliableFrame() throws {
        let events: [InputEvent] = [
            .pointerMove(deltaX: -2.5, deltaY: 4, absoluteX: 100, absoluteY: 200),
            .mouseButton(button: .left, isDown: true, clickCount: 2),
            .mouseButton(button: .right, isDown: false, clickCount: 1),
            .mouseButton(button: .center, isDown: true, clickCount: 1),
            .mouseButton(button: .other, isDown: false, clickCount: 1),
            .scroll(deltaX: 1.5, deltaY: -3.25, isContinuous: true),
            .scroll(deltaX: 0, deltaY: 3, isContinuous: false),
            .gesture(serializedEvent: Data([0, 1, 2, 255])),
            .key(code: 53, isDown: true, isRepeat: false),
            .key(code: 12, isDown: false, isRepeat: true),
            .flags(rawValue: UInt64.max)
        ]

        for (sequence, event) in events.enumerated() {
            let frame = makeInputFrame(sequence: UInt64(sequence), event: event)
            let encoded = try WireFrameCodec.encodeInput(frame)
            let (kind, payload) = try WireFrameCodec.decode(encoded)
            XCTAssertEqual(kind, .inputBinary)
            XCTAssertEqual(try WireFrameCodec.decodeInput(payload), frame)
        }
    }

    func testRealtimeFrameRoundTripsAndBuildsReliableFallback() throws {
        let controllerID = DeviceID()
        let frame = RealtimePointerFrame(
            workspaceID: WorkspaceID(),
            sessionID: SessionID(),
            controllerID: controllerID,
            epoch: .init(generation: 3, controllerID: controllerID),
            generation: 4,
            sequence: 5,
            deltaX: 6,
            deltaY: -7,
            cumulativeDeltaX: 20,
            cumulativeDeltaY: -30,
            absoluteX: 400,
            absoluteY: 500,
            timestampNanos: 600
        )

        let encoded = try WireFrameCodec.encodeRealtimePointer(frame)
        let (kind, payload) = try WireFrameCodec.decode(encoded)

        XCTAssertEqual(kind, .realtimePointerBinary)
        XCTAssertEqual(try WireFrameCodec.decodeRealtimePointer(payload), frame)
        XCTAssertEqual(
            frame.reliableFallback.event,
            .pointerMove(deltaX: 6, deltaY: -7, absoluteX: 400, absoluteY: 500)
        )
    }

    func testCodecRejectsEveryInvalidHeaderAndProtocolVersion() throws {
        XCTAssertThrowsError(try WireFrameCodec.decode(Data())) { error in
            XCTAssertEqual(error as? ControlProtocolError, .malformedFrame)
        }
        XCTAssertThrowsError(try WireFrameCodec.decode(Data([0, 0, 0, 0, 255]))) { error in
            XCTAssertEqual(error as? ControlProtocolError, .malformedFrame)
        }
        XCTAssertThrowsError(try WireFrameCodec.decode(Data([0, 0, 0, 2, 1, 0]))) { error in
            XCTAssertEqual(error as? ControlProtocolError, .malformedFrame)
        }
        let oversized = WireFrameCodec.maximumPayloadSize + 1
        let header = Data([
            UInt8((oversized >> 24) & 0xff),
            UInt8((oversized >> 16) & 0xff),
            UInt8((oversized >> 8) & 0xff),
            UInt8(oversized & 0xff),
            WireFrameKind.controlJSON.rawValue
        ])
        XCTAssertThrowsError(try WireFrameCodec.decode(header)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .oversizedFrame(oversized))
        }

        let future = ControlEnvelope(version: 999, message: .releaseAll(SessionID()))
        let (_, payload) = try WireFrameCodec.decode(WireFrameCodec.encodeControl(future))
        XCTAssertThrowsError(try WireFrameCodec.decodeControl(payload)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .unsupportedVersion(999))
        }
        XCTAssertThrowsError(try WireFrameCodec.decodeControl(Data([0xff])))
        XCTAssertThrowsError(try WireFrameCodec.decodeInput(Data([0xff])))
        XCTAssertThrowsError(try WireFrameCodec.decodeRealtimePointer(Data([0xff])))
    }

    private func makeInputFrame(sequence: UInt64, event: InputEvent) -> InputFrame {
        let controllerID = DeviceID()
        return InputFrame(
            workspaceID: WorkspaceID(),
            sessionID: SessionID(),
            controllerID: controllerID,
            epoch: .init(generation: 1, controllerID: controllerID),
            sequence: sequence,
            timestampNanos: sequence + 10,
            event: event
        )
    }
}
