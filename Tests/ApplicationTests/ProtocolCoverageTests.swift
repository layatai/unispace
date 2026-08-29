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
            .gesture(
                serializedEvent: Data([0, 1, 2, 255]),
                portable: PortableGesture(kind: .magnify, phase: .changed, value: 0.125)
            ),
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

    func testEveryControlMessageRoundTripsThroughPortableWireCodec() throws {
        let deviceID = fixedDeviceID("20212223-2425-2627-2829-2A2B2C2D2E2F")
        let workspaceID = fixedWorkspaceID("00010203-0405-0607-0809-0A0B0C0D0E0F")
        let sessionID = fixedSessionID("10111213-1415-1617-1819-1A1B1C1D1E1F")
        let displayID = fixedDisplayID("40414243-4445-4647-4849-4A4B4C4D4E4F")
        let epoch = ControllerEpoch(generation: 7, controllerID: deviceID)
        let display = DisplayDescriptor(
            id: displayID,
            deviceID: deviceID,
            name: "Windows Display",
            frame: .init(x: -1920, y: 0, width: 1920, height: 1080),
            scaleFactor: 1.25,
            isMain: true
        )
        let device = DeviceDescriptor(
            id: deviceID,
            name: "Windows PC",
            displays: [display],
            peerAddresses: [try PeerAddress("windows.tailnet.ts.net")],
            capabilities: [.crossPlatformInputV2, .quicStreamV2, .udpPointerV2],
            platform: .windows
        )
        let workspace = WorkspaceSnapshot(
            id: workspaceID,
            name: "Portable Workspace",
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
            let encoded = try WireFrameCodec.encodePortableControl(envelope)
            let (kind, payload) = try WireFrameCodec.decode(encoded)
            XCTAssertEqual(kind, .controlJSONV2)
            XCTAssertEqual(try WireFrameCodec.decodePortableControl(payload), envelope)
        }
    }

    func testEveryPortableInputEventRoundTripsThroughBigEndianCodec() throws {
        let events: [PortableInputEvent] = [
            .pointerMove(deltaX: -2.5, deltaY: 4, absoluteX: 100, absoluteY: 200),
            .mouseButton(button: .left, isDown: true, clickCount: 2),
            .mouseButton(button: .other, isDown: false, clickCount: 1),
            .scroll(deltaX: 1.5, deltaY: -3.25, isContinuous: true),
            .key(usage: 0x04, isDown: true, isRepeat: false),
            .modifiers([.shift, .command, .capsLock]),
            .gesture(PortableGesture(
                kind: .swipe,
                phase: .ended,
                deltaX: 1,
                deltaY: 0
            )),
            .gesture(PortableGesture(
                kind: .workspaceSwipe,
                phase: .changed,
                deltaY: 1
            )),
            .gesture(PortableGesture(
                kind: .desktopPinch,
                phase: .changed,
                value: 1
            )),
        ]

        for (sequence, event) in events.enumerated() {
            let frame = makePortableInputFrame(sequence: UInt64(sequence), event: event)
            let encoded = try WireFrameCodec.encodePortableInput(frame)
            let (kind, payload) = try WireFrameCodec.decode(encoded)
            XCTAssertEqual(kind, .inputBinaryV2)
            XCTAssertEqual(try WireFrameCodec.decodePortableInput(payload), frame)
        }
    }

    func testPortableInputGoldenVectorMatchesWindowsCodec() throws {
        let frame = PortableInputFrame(
            workspaceID: fixedWorkspaceID("00010203-0405-0607-0809-0A0B0C0D0E0F"),
            sessionID: fixedSessionID("10111213-1415-1617-1819-1A1B1C1D1E1F"),
            controllerID: fixedDeviceID("20212223-2425-2627-2829-2A2B2C2D2E2F"),
            epoch: .init(
                generation: 4,
                controllerID: fixedDeviceID("30313233-3435-3637-3839-3A3B3C3D3E3F")
            ),
            sequence: 5,
            timestampNanos: 6,
            event: .key(usage: 0x04, isDown: true, isRepeat: false)
        )

        XCTAssertEqual(
            try WireFrameCodec.encodePortableInput(frame).hexString,
            "0000005f050002000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f0000000000000004303132333435363738393a3b3c3d3e3f000000000000000500000000000000060400040100"
        )
    }

    func testPortableControlGoldenVectorMatchesWindowsCodec() throws {
        let sessionID = fixedSessionID("10111213-1415-1617-1819-1A1B1C1D1E1F")
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectorData = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "Documentation/Protocol/interop-vectors.json"
        ))
        let vectors = try XCTUnwrap(
            JSONSerialization.jsonObject(with: vectorData) as? [String: Any]
        )
        let wire = try XCTUnwrap(vectors["wireV2"] as? [String: String])
        XCTAssertEqual(
            try WireFrameCodec.encodePortableControl(
                ControlEnvelope(message: .releaseAll(sessionID))
            ).hexString,
            wire["controlReleaseAllFrameHex"]
        )
    }

    func testPortableRealtimePointerRoundTripsAndBuildsReliableFallback() throws {
        let controllerID = fixedDeviceID("20212223-2425-2627-2829-2A2B2C2D2E2F")
        let frame = PortableRealtimePointerFrame(
            workspaceID: fixedWorkspaceID("00010203-0405-0607-0809-0A0B0C0D0E0F"),
            sessionID: fixedSessionID("10111213-1415-1617-1819-1A1B1C1D1E1F"),
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

        let encoded = try WireFrameCodec.encodePortableRealtimePointer(frame)
        let (kind, payload) = try WireFrameCodec.decode(encoded)

        XCTAssertEqual(kind, .realtimePointerBinaryV2)
        XCTAssertEqual(try WireFrameCodec.decodePortableRealtimePointer(payload), frame)
        XCTAssertEqual(
            frame.reliableFallback.event,
            .pointerMove(deltaX: 6, deltaY: -7, absoluteX: 400, absoluteY: 500)
        )
    }

    func testMacInputMapsToPortableHIDAndNormalizedModifiers() throws {
        let controllerID = fixedDeviceID("20212223-2425-2627-2829-2A2B2C2D2E2F")
        let input = InputFrame(
            workspaceID: fixedWorkspaceID("00010203-0405-0607-0809-0A0B0C0D0E0F"),
            sessionID: fixedSessionID("10111213-1415-1617-1819-1A1B1C1D1E1F"),
            controllerID: controllerID,
            epoch: .init(generation: 1, controllerID: controllerID),
            sequence: 1,
            timestampNanos: 2,
            event: .key(code: 0, isDown: true, isRepeat: false)
        )
        XCTAssertEqual(
            PortableInputMapper.map(input)?.event,
            .key(usage: 0x04, isDown: true, isRepeat: false)
        )
        XCTAssertEqual(
            PortableInputMapper.map(.key(code: 36, isDown: true, isRepeat: false)),
            .key(usage: 0x28, isDown: true, isRepeat: false)
        )
        XCTAssertEqual(
            PortableInputMapper.map(.key(code: 36, isDown: false, isRepeat: false)),
            .key(usage: 0x28, isDown: false, isRepeat: false)
        )
        let portableGesture = PortableGesture(
            kind: .magnify,
            phase: .changed,
            value: 0.125
        )
        XCTAssertEqual(
            PortableInputMapper.map(.gesture(serializedEvent: Data([1]), portable: portableGesture)),
            .gesture(portableGesture)
        )
        let specialKeyMappings: [(keyCode: UInt16, usage: UInt16)] = [
            (10, 0x64),  // ISO Section -> Keyboard Non-US Backslash
            (64, 0x6C),  // F17
            (79, 0x6D),  // F18
            (80, 0x6E),  // F19
            (90, 0x6F),  // F20
            (93, 0x89),  // JIS Yen -> International3
            (94, 0x87),  // JIS Underscore -> International1
            (95, 0x85),  // JIS Keypad Comma
            (102, 0x91), // JIS Eisu -> LANG2
            (104, 0x90), // JIS Kana -> LANG1
            (110, 0x65), // Contextual Menu -> Application
        ]
        for mapping in specialKeyMappings {
            XCTAssertEqual(
                PortableInputMapper.map(.key(code: mapping.keyCode, isDown: true, isRepeat: false)),
                .key(usage: mapping.usage, isDown: true, isRepeat: false)
            )
        }
        XCTAssertEqual(
            PortableInputMapper.map(.flags(rawValue: 0x001F_0000)),
            .modifiers([.shift, .control, .option, .command, .capsLock])
        )
        XCTAssertNil(PortableInputMapper.map(.key(code: .max, isDown: true, isRepeat: false)))
        XCTAssertNil(PortableInputMapper.map(.gesture(serializedEvent: Data([1]))))
        XCTAssertEqual(
            PortableInputMapper.map(.pointerMove(
                deltaX: 1,
                deltaY: -2,
                absoluteX: 30,
                absoluteY: 40
            )),
            .pointerMove(deltaX: 1, deltaY: -2, absoluteX: 30, absoluteY: 40)
        )
        XCTAssertEqual(
            PortableInputMapper.map(.mouseButton(button: .right, isDown: true, clickCount: .max)),
            .mouseButton(button: .right, isDown: true, clickCount: .max)
        )
        XCTAssertEqual(
            PortableInputMapper.map(.scroll(deltaX: 3, deltaY: 4, isContinuous: true)),
            .scroll(deltaX: 3, deltaY: 4, isContinuous: true)
        )
        XCTAssertEqual(
            PortableInputMapper.modifierMask(rawFlags: 0x0080_0000),
            [.function]
        )

        let realtime = RealtimePointerFrame(
            workspaceID: input.workspaceID,
            sessionID: input.sessionID,
            controllerID: input.controllerID,
            epoch: input.epoch,
            generation: 2,
            sequence: 3,
            deltaX: 4,
            deltaY: 5,
            cumulativeDeltaX: 6,
            cumulativeDeltaY: 7,
            absoluteX: 8,
            absoluteY: 9,
            timestampNanos: 10
        )
        let portableRealtime = PortableInputMapper.map(realtime)
        XCTAssertEqual(portableRealtime.generation, 2)
        XCTAssertEqual(portableRealtime.cumulativeDeltaX, 6)
        XCTAssertEqual(portableRealtime.absoluteY, 9)
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
        XCTAssertThrowsError(try WireFrameCodec.decodePortableControl(Data([0xff])))
        XCTAssertThrowsError(try WireFrameCodec.decodePortableInput(Data([0xff])))
        XCTAssertThrowsError(try WireFrameCodec.decodePortableRealtimePointer(Data([0xff])))

        let sessionID = fixedSessionID("10111213-1415-1617-1819-1A1B1C1D1E1F")
        let futurePortableControl = Data(
            "{\"payload\":{\"sessionID\":{\"rawValue\":\"\(sessionID.rawValue.uuidString)\"}},\"type\":\"releaseAll\",\"version\":999}".utf8
        )
        XCTAssertThrowsError(try WireFrameCodec.decodePortableControl(futurePortableControl)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .unsupportedVersion(999))
        }
        let unknownPortableControl = Data(
            "{\"payload\":{},\"type\":\"futureMessage\",\"version\":2}".utf8
        )
        XCTAssertThrowsError(try WireFrameCodec.decodePortableControl(unknownPortableControl)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .malformedFrame)
        }

        var portableInput = try WireFrameCodec.encodePortableInput(
            makePortableInputFrame(sequence: 1, event: .mouseButton(button: .left, isDown: true, clickCount: 1))
        )
        portableInput[5] = 0
        portableInput[6] = 3
        let (_, futureInputPayload) = try WireFrameCodec.decode(portableInput)
        XCTAssertThrowsError(try WireFrameCodec.decodePortableInput(futureInputPayload)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .unsupportedVersion(3))
        }

        portableInput = try WireFrameCodec.encodePortableInput(
            makePortableInputFrame(sequence: 2, event: .mouseButton(button: .left, isDown: true, clickCount: 1))
        )
        portableInput[5 + 91] = 255
        let (_, badButtonPayload) = try WireFrameCodec.decode(portableInput)
        XCTAssertThrowsError(try WireFrameCodec.decodePortableInput(badButtonPayload)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .malformedFrame)
        }

        portableInput = try WireFrameCodec.encodePortableInput(
            makePortableInputFrame(sequence: 3, event: .key(usage: 4, isDown: true, isRepeat: false))
        )
        portableInput[5 + 90] = 255
        let (_, badEventPayload) = try WireFrameCodec.decode(portableInput)
        XCTAssertThrowsError(try WireFrameCodec.decodePortableInput(badEventPayload)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .malformedFrame)
        }

        portableInput = try WireFrameCodec.encodePortableInput(
            makePortableInputFrame(
                sequence: 4,
                event: .gesture(PortableGesture(kind: .swipe, phase: .changed, deltaX: 1))
            )
        )
        portableInput[5 + 91] = 255
        let (_, badGestureKindPayload) = try WireFrameCodec.decode(portableInput)
        XCTAssertThrowsError(try WireFrameCodec.decodePortableInput(badGestureKindPayload)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .malformedFrame)
        }

        portableInput = try WireFrameCodec.encodePortableInput(
            makePortableInputFrame(
                sequence: 5,
                event: .gesture(PortableGesture(kind: .swipe, phase: .changed, deltaX: 1))
            )
        )
        portableInput[5 + 92] = 255
        let (_, badGesturePhasePayload) = try WireFrameCodec.decode(portableInput)
        XCTAssertThrowsError(try WireFrameCodec.decodePortableInput(badGesturePhasePayload)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .malformedFrame)
        }

        let controllerID = fixedDeviceID("20212223-2425-2627-2829-2A2B2C2D2E2F")
        var pointer = try WireFrameCodec.encodePortableRealtimePointer(.init(
            workspaceID: fixedWorkspaceID("00010203-0405-0607-0809-0A0B0C0D0E0F"),
            sessionID: sessionID,
            controllerID: controllerID,
            epoch: .init(generation: 1, controllerID: controllerID),
            generation: 1,
            sequence: 1,
            deltaX: 0,
            deltaY: 0,
            cumulativeDeltaX: 0,
            cumulativeDeltaY: 0,
            absoluteX: 0,
            absoluteY: 0,
            timestampNanos: 1
        ))
        pointer[5] = 0
        pointer[6] = 3
        let (_, futurePointerPayload) = try WireFrameCodec.decode(pointer)
        XCTAssertThrowsError(try WireFrameCodec.decodePortableRealtimePointer(futurePointerPayload)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .unsupportedVersion(3))
        }
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

    private func makePortableInputFrame(sequence: UInt64, event: PortableInputEvent) -> PortableInputFrame {
        let controllerID = fixedDeviceID("20212223-2425-2627-2829-2A2B2C2D2E2F")
        return PortableInputFrame(
            workspaceID: fixedWorkspaceID("00010203-0405-0607-0809-0A0B0C0D0E0F"),
            sessionID: fixedSessionID("10111213-1415-1617-1819-1A1B1C1D1E1F"),
            controllerID: controllerID,
            epoch: .init(generation: 1, controllerID: controllerID),
            sequence: sequence,
            timestampNanos: sequence + 10,
            event: event
        )
    }

    private func fixedDeviceID(_ value: String) -> DeviceID {
        DeviceID(rawValue: UUID(uuidString: value)!)
    }

    private func fixedWorkspaceID(_ value: String) -> WorkspaceID {
        WorkspaceID(rawValue: UUID(uuidString: value)!)
    }

    private func fixedSessionID(_ value: String) -> SessionID {
        SessionID(rawValue: UUID(uuidString: value)!)
    }

    private func fixedDisplayID(_ value: String) -> DisplayID {
        DisplayID(rawValue: UUID(uuidString: value)!)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
