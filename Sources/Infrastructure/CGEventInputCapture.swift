import CoreGraphics
import Foundation
import UniSpaceApplication
import UniSpaceDomain

let uniSpaceSyntheticEventMarker: Int64 = 0x554E_4953_5041_4345

struct CursorSuppressionState: Equatable {
    private(set) var anchor: CGPoint?

    mutating func setEnabled(_ enabled: Bool, currentPosition: @autoclosure () -> CGPoint?) {
        if enabled {
            if anchor == nil { anchor = currentPosition() }
        } else {
            anchor = nil
        }
    }

    func restorationPoint(for type: CGEventType) -> CGPoint? {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            anchor
        default:
            nil
        }
    }
}

public enum InputCaptureError: Error, Equatable {
    case permissionDenied
    case eventTapCreationFailed
}

public final class CGEventInputCapture: InputCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var callback: (@Sendable (InputEvent) -> Bool)?
    private var suppressionEnabled = false
    private var cursorSuppression = CursorSuppressionState()

    public init() {}

    public func start(handler: @escaping @Sendable (InputEvent) -> Bool) throws {
        guard CGPreflightListenEventAccess() else { throw InputCaptureError.permissionDenied }
        lock.lock()
        defer { lock.unlock() }
        if eventTap != nil { return }
        callback = handler

        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: uniSpaceEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            callback = nil
            throw InputCaptureError.eventTapCreationFailed
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        callback = nil
        suppressionEnabled = false
        cursorSuppression.setEnabled(false, currentPosition: nil)
    }

    public func setSuppressionEnabled(_ enabled: Bool) {
        lock.lock()
        suppressionEnabled = enabled
        cursorSuppression.setEnabled(enabled, currentPosition: CGEvent(source: nil)?.location)
        lock.unlock()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            lock.unlock()
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == uniSpaceSyntheticEventMarker {
            return false
        }
        guard let input = Self.convert(type: type, event: event) else { return false }
        lock.lock()
        let callback = callback
        let suppress = suppressionEnabled
        let restorationPoint = suppress ? cursorSuppression.restorationPoint(for: type) : nil
        lock.unlock()
        let handled = callback?(input) ?? false
        if let restorationPoint {
            CGWarpMouseCursorPosition(restorationPoint)
        }
        return handled || suppress
    }

    private static func convert(type: CGEventType, event: CGEvent) -> InputEvent? {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return .pointerMove(
                deltaX: event.getDoubleValueField(.mouseEventDeltaX),
                deltaY: event.getDoubleValueField(.mouseEventDeltaY),
                absoluteX: event.location.x,
                absoluteY: event.location.y
            )
        case .leftMouseDown, .leftMouseUp:
            return .mouseButton(button: .left, isDown: type == .leftMouseDown, clickCount: Int(event.getIntegerValueField(.mouseEventClickState)))
        case .rightMouseDown, .rightMouseUp:
            return .mouseButton(button: .right, isDown: type == .rightMouseDown, clickCount: Int(event.getIntegerValueField(.mouseEventClickState)))
        case .otherMouseDown, .otherMouseUp:
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            let button: PointerButton = number == 2 ? .center : .other
            return .mouseButton(button: button, isDown: type == .otherMouseDown, clickCount: Int(event.getIntegerValueField(.mouseEventClickState)))
        case .scrollWheel:
            return .scroll(
                deltaX: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                deltaY: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            )
        case .keyDown, .keyUp:
            return .key(
                code: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                isDown: type == .keyDown,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .flagsChanged:
            return .flags(rawValue: event.flags.rawValue)
        default:
            return nil
        }
    }
}

private func uniSpaceEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<CGEventInputCapture>.fromOpaque(userInfo).takeUnretainedValue()
    return capture.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
