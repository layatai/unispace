import AppKit
import CoreGraphics
import XCTest
@testable import UniSpaceInfrastructure
import UniSpaceDomain

final class InputPipelineTests: XCTestCase {
    func testCaptureStartReportsPermissionAndTapCreationFailuresDeterministically() {
        let denied = CGEventInputCapture(
            mouseAssociationHandler: { _ in },
            permissionChecker: { false },
            eventTapFactory: { _, _ in XCTFail("Tap factory must not run without permission"); return nil }
        )
        XCTAssertThrowsError(try denied.start { _ in false }) { error in
            XCTAssertEqual(error as? InputCaptureError, .permissionDenied)
        }

        let tapFailure = CGEventInputCapture(
            mouseAssociationHandler: { _ in },
            permissionChecker: { true },
            eventTapFactory: { mask, _ in
                XCTAssertNotEqual(mask, 0)
                return nil
            }
        )
        XCTAssertThrowsError(try tapFailure.start { _ in false }) { error in
            XCTAssertEqual(error as? InputCaptureError, .eventTapCreationFailed)
        }
    }

    func testCaptureConvertsEverySupportedCoreGraphicsEvent() throws {
        let mouse = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 30, y: 40),
            mouseButton: .left
        ))
        mouse.setDoubleValueField(.mouseEventDeltaX, value: 3)
        mouse.setDoubleValueField(.mouseEventDeltaY, value: -2)
        XCTAssertEqual(
            CGEventInputCapture.convert(type: .mouseMoved, event: mouse),
            .pointerMove(deltaX: 3, deltaY: -2, absoluteX: 30, absoluteY: 40)
        )
        XCTAssertEqual(
            CGEventInputCapture.convert(type: .rightMouseDragged, event: mouse),
            .pointerMove(deltaX: 3, deltaY: -2, absoluteX: 30, absoluteY: 40)
        )

        mouse.setIntegerValueField(.mouseEventClickState, value: 2)
        XCTAssertEqual(
            CGEventInputCapture.convert(type: .leftMouseDown, event: mouse),
            .mouseButton(button: .left, isDown: true, clickCount: 2)
        )
        XCTAssertEqual(
            CGEventInputCapture.convert(type: .leftMouseUp, event: mouse),
            .mouseButton(button: .left, isDown: false, clickCount: 2)
        )
        XCTAssertEqual(
            CGEventInputCapture.convert(type: .rightMouseDown, event: mouse),
            .mouseButton(button: .right, isDown: true, clickCount: 2)
        )
        XCTAssertEqual(
            CGEventInputCapture.convert(type: .rightMouseUp, event: mouse),
            .mouseButton(button: .right, isDown: false, clickCount: 2)
        )
        mouse.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        XCTAssertEqual(
            CGEventInputCapture.convert(type: .otherMouseDown, event: mouse),
            .mouseButton(button: .center, isDown: true, clickCount: 2)
        )
        mouse.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        XCTAssertEqual(
            CGEventInputCapture.convert(type: .otherMouseUp, event: mouse),
            .mouseButton(button: .other, isDown: false, clickCount: 2)
        )

        let scroll = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: -5,
            wheel2: 3,
            wheel3: 0
        ))
        scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        XCTAssertEqual(
            CGEventInputCapture.convert(type: .scrollWheel, event: scroll),
            .scroll(deltaX: 3, deltaY: -5, isContinuous: true)
        )

        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        key.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertEqual(
            CGEventInputCapture.convert(type: .keyDown, event: key),
            .key(code: 53, isDown: true, isRepeat: true)
        )
        XCTAssertEqual(
            CGEventInputCapture.convert(type: .keyUp, event: key),
            .key(code: 53, isDown: false, isRepeat: true)
        )
        key.flags = [.maskCommand, .maskShift]
        XCTAssertEqual(
            CGEventInputCapture.convert(type: .flagsChanged, event: key),
            .flags(rawValue: key.flags.rawValue)
        )
        XCTAssertNil(CGEventInputCapture.convert(type: .null, event: key))
    }

    func testCaptureFiltersSyntheticEventsAndCombinesCallbackWithSuppression() throws {
        let associations = LockedValues<Bool>()
        let warped = LockedValues<CGPoint>()
        let handledEvents = LockedValues<InputEvent>()
        let capture = CGEventInputCapture(
            mouseAssociationHandler: associations.append,
            cursorWarpHandler: warped.append,
            handler: { event in
                handledEvents.append(event)
                return true
            }
        )
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 10, y: 20),
            mouseButton: .left
        ))
        event.setDoubleValueField(.mouseEventDeltaX, value: 1)

        XCTAssertTrue(capture.handle(type: .mouseMoved, event: event))
        XCTAssertEqual(handledEvents.values.count, 1)
        event.setIntegerValueField(.eventSourceUserData, value: uniSpaceSyntheticEventMarker)
        XCTAssertFalse(capture.handle(type: .mouseMoved, event: event))
        XCTAssertEqual(handledEvents.values.count, 1)

        let commandC = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 8,
            keyDown: true
        ))
        commandC.flags = [.maskCommand]
        XCTAssertTrue(capture.handle(type: .keyDown, event: commandC))
        XCTAssertEqual(Array(handledEvents.values.suffix(2)), [
            .flags(rawValue: CGEventFlags.maskCommand.rawValue),
            .key(code: 8, isDown: true, isRepeat: false),
        ])

        let suppressionEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 11, y: 21),
            mouseButton: .left
        ))
        capture.setSuppressionEnabled(true)
        XCTAssertTrue(capture.isSuppressionEnabled)
        XCTAssertTrue(capture.handle(type: .mouseMoved, event: suppressionEvent))
        XCTAssertEqual(associations.values, [false])
        XCTAssertEqual(warped.values.count, 1)
        XCTAssertFalse(capture.handle(type: .tapDisabledByTimeout, event: suppressionEvent))
        XCTAssertFalse(capture.handle(type: .tapDisabledByUserInput, event: suppressionEvent))
        capture.stop()
        XCTAssertFalse(capture.isSuppressionEnabled)
        XCTAssertEqual(associations.values, [false, true])
    }

    func testInjectorMapsActivationAndEveryInputKindWithoutPostingGlobally() throws {
        let posted = LockedValues<EventSnapshot>()
        let warped = LockedValues<CGPoint>()
        let bounds = [CGRect(x: 0, y: 0, width: 100, height: 80)]
        let injector = CGEventInputInjector(
            displayBoundsProvider: { bounds },
            initialCursorPosition: CGPoint(x: 50, y: 40),
            eventPoster: { posted.append(EventSnapshot($0)) },
            cursorWarpHandler: warped.append
        )
        let deviceID = DeviceID()
        let display = DisplayDescriptor(
            id: DisplayID(),
            deviceID: deviceID,
            name: "Display",
            frame: .init(x: 0, y: 0, width: 100, height: 80),
            scaleFactor: 2,
            isMain: true
        )
        for edge in DisplayEdge.allCases {
            injector.activate(on: display, enteringFrom: edge, normalizedPosition: 0.25)
        }
        XCTAssertEqual(warped.values, [
            CGPoint(x: 2, y: 20),
            CGPoint(x: 98, y: 20),
            CGPoint(x: 25, y: 78),
            CGPoint(x: 25, y: 2)
        ])

        injector.inject(.flags(rawValue: CGEventFlags.maskCommand.rawValue))
        injector.inject(.key(code: 8, isDown: true, isRepeat: false))
        injector.inject(.key(code: 8, isDown: false, isRepeat: false))
        injector.inject(.key(code: 9, isDown: true, isRepeat: false))
        injector.inject(.key(code: 9, isDown: false, isRepeat: false))
        injector.inject(.flags(rawValue: 0))
        injector.inject(.mouseButton(button: .left, isDown: true, clickCount: 2))
        injector.inject(.pointerMove(deltaX: 500, deltaY: 0, absoluteX: 0, absoluteY: 0))
        injector.inject(.scroll(deltaX: 2.4, deltaY: -4.6, isContinuous: true))

        let gestureType = try XCTUnwrap(CGEventType(rawValue: UInt32(NSEvent.EventType.magnify.rawValue)))
        let gesture = try XCTUnwrap(CGEvent(source: nil))
        gesture.type = gestureType
        injector.inject(.gesture(serializedEvent: try XCTUnwrap(gesture.data) as Data))
        injector.inject(.mouseButton(button: .left, isDown: false, clickCount: 2))
        injector.releaseAll()

        let snapshots = posted.values
        XCTAssertTrue(snapshots.allSatisfy { $0.marker == uniSpaceSyntheticEventMarker })
        let shortcutKeyDowns = snapshots.filter {
            $0.type == .keyDown && ($0.keyCode == 8 || $0.keyCode == 9)
        }
        XCTAssertEqual(shortcutKeyDowns.map(\.keyCode), [8, 9])
        XCTAssertTrue(shortcutKeyDowns.allSatisfy { $0.flags.contains(.maskCommand) })
        XCTAssertTrue(snapshots.contains { $0.type == .leftMouseDown && $0.clickCount == 2 })
        XCTAssertTrue(snapshots.contains { $0.type == .leftMouseDragged && $0.location == CGPoint(x: 100, y: 2) })
        XCTAssertTrue(snapshots.contains { $0.type == .scrollWheel })
        XCTAssertTrue(snapshots.contains { $0.type.rawValue == gestureType.rawValue })
        XCTAssertTrue(snapshots.contains { $0.type == .keyUp && $0.keyCode == 8 })
        XCTAssertTrue(snapshots.contains { $0.type == .keyUp && $0.keyCode == 9 })
        let commandEvents = snapshots.filter {
            $0.type == .flagsChanged && $0.keyCode == 55
        }
        XCTAssertEqual(commandEvents.count, 2)
        XCTAssertTrue(commandEvents[0].flags.contains(.maskCommand))
        XCTAssertFalse(commandEvents[1].flags.contains(.maskCommand))
    }

    func testInjectorConstrainsToNearestDisplayAndRejectsInvalidGestureData() {
        let first = CGRect(x: 0, y: 0, width: 100, height: 100)
        let second = CGRect(x: 200, y: 0, width: 100, height: 100)
        XCTAssertEqual(
            CGEventInputInjector.constrainedPosition(CGPoint(x: 150, y: 25), to: [first, second]),
            CGPoint(x: 100, y: 25)
        )
        XCTAssertEqual(
            CGEventInputInjector.constrainedPosition(CGPoint(x: 25, y: 25), to: [first]),
            CGPoint(x: 25, y: 25)
        )
        XCTAssertEqual(
            CGEventInputInjector.constrainedPosition(CGPoint(x: -10, y: -20), to: []),
            CGPoint(x: -10, y: -20)
        )
        XCTAssertNil(CGEventInputInjector.gestureEvent(from: Data([1, 2, 3]), at: .zero))
    }
}

private struct EventSnapshot: Sendable {
    let type: CGEventType
    let location: CGPoint
    let marker: Int64
    let clickCount: Int64
    let keyCode: Int64
    let flags: CGEventFlags

    init(_ event: CGEvent) {
        type = event.type
        location = event.location
        marker = event.getIntegerValueField(.eventSourceUserData)
        clickCount = event.getIntegerValueField(.mouseEventClickState)
        keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        flags = event.flags
    }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}
