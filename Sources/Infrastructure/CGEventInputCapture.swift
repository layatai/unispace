import AppKit
import CoreGraphics
import Foundation
import UniSpaceApplication
import UniSpaceDomain

let uniSpaceSyntheticEventMarker: Int64 = 0x554E_4953_5041_4345

struct CursorSuppressionState: Equatable {
    private(set) var anchor: CGPoint?
    private(set) var isEnabled = false

    @discardableResult
    mutating func setEnabled(_ enabled: Bool, currentPosition: @autoclosure () -> CGPoint?) -> Bool {
        guard enabled != isEnabled else { return false }
        isEnabled = enabled
        if enabled {
            anchor = currentPosition()
        } else {
            anchor = nil
        }
        return true
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
    typealias MouseAssociationHandler = @Sendable (_ connected: Bool) -> Void
    typealias CursorWarpHandler = @Sendable (CGPoint) -> Void
    typealias PermissionChecker = @Sendable () -> Bool
    typealias EventTapFactory = @Sendable (CGEventMask, UnsafeMutableRawPointer) -> CFMachPort?

    static let gestureEventTypes: [CGEventType] = [
        NSEvent.EventType.gesture,
        .magnify,
        .swipe,
        .rotate,
        .beginGesture,
        .endGesture,
        .smartMagnify
    ].compactMap { CGEventType(rawValue: UInt32($0.rawValue)) }

    static let capturedEventTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .scrollWheel, .keyDown, .keyUp, .flagsChanged
    ] + gestureEventTypes

    private let lock = NSLock()
    private let mouseAssociationHandler: MouseAssociationHandler
    private let cursorWarpHandler: CursorWarpHandler
    private let permissionChecker: PermissionChecker
    private let eventTapFactory: EventTapFactory
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var callback: (@Sendable (InputEvent) -> Bool)?
    private var suppressionEnabled = false
    private var cursorSuppression = CursorSuppressionState()

    public convenience init() {
        self.init(
            mouseAssociationHandler: { connected in
                _ = CGAssociateMouseAndMouseCursorPosition(connected ? 1 : 0)
            },
            cursorWarpHandler: { _ = CGWarpMouseCursorPosition($0) },
            permissionChecker: CGPreflightListenEventAccess,
            eventTapFactory: Self.makeEventTap
        )
    }

    init(
        mouseAssociationHandler: @escaping MouseAssociationHandler,
        cursorWarpHandler: @escaping CursorWarpHandler = { _ = CGWarpMouseCursorPosition($0) },
        permissionChecker: @escaping PermissionChecker = CGPreflightListenEventAccess,
        eventTapFactory: @escaping EventTapFactory = CGEventInputCapture.makeEventTap,
        handler: (@Sendable (InputEvent) -> Bool)? = nil
    ) {
        self.mouseAssociationHandler = mouseAssociationHandler
        self.cursorWarpHandler = cursorWarpHandler
        self.permissionChecker = permissionChecker
        self.eventTapFactory = eventTapFactory
        callback = handler
    }

    deinit {
        if cursorSuppression.isEnabled { mouseAssociationHandler(true) }
    }

    public var isSuppressionEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suppressionEnabled
    }

    public func start(handler: @escaping @Sendable (InputEvent) -> Bool) throws {
        guard permissionChecker() else { throw InputCaptureError.permissionDenied }
        lock.lock()
        defer { lock.unlock() }
        if eventTap != nil { return }
        callback = handler

        let mask = Self.capturedEventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let tap = eventTapFactory(mask, Unmanaged.passUnretained(self).toOpaque()) else {
            callback = nil
            throw InputCaptureError.eventTapCreationFailed
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static func makeEventTap(mask: CGEventMask, userInfo: UnsafeMutableRawPointer) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: uniSpaceEventTapCallback,
            userInfo: userInfo
        )
    }

    public func stop() {
        lock.lock()
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
        let associationChanged = cursorSuppression.setEnabled(false, currentPosition: nil)
        if associationChanged { mouseAssociationHandler(true) }
        lock.unlock()
    }

    public func setSuppressionEnabled(_ enabled: Bool) {
        lock.lock()
        suppressionEnabled = enabled
        let associationChanged = cursorSuppression.setEnabled(
            enabled,
            currentPosition: CGEvent(source: nil)?.location
        )
        if associationChanged { mouseAssociationHandler(!enabled) }
        lock.unlock()
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
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
            cursorWarpHandler(restorationPoint)
        }
        return handled || suppress
    }

    static func convert(type: CGEventType, event: CGEvent) -> InputEvent? {
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
            guard gestureEventTypes.contains(where: { $0.rawValue == type.rawValue }),
                  let serializedEvent = event.data else { return nil }
            return .gesture(
                serializedEvent: serializedEvent as Data,
                portable: portableGesture(event: event)
            )
        }
    }

    static func portableGesture(event: CGEvent) -> PortableGesture? {
        guard let appKitEvent = NSEvent(cgEvent: event) else { return nil }
        let phase = portablePhase(appKitEvent.phase)
        switch appKitEvent.type {
        case .magnify:
            return PortableGesture(kind: .magnify, phase: phase, value: appKitEvent.magnification)
        case .swipe:
            return PortableGesture(
                kind: .swipe,
                phase: phase,
                deltaX: appKitEvent.deltaX,
                deltaY: appKitEvent.deltaY
            )
        case .rotate:
            return PortableGesture(kind: .rotate, phase: phase, value: Double(appKitEvent.rotation))
        case .smartMagnify:
            return PortableGesture(kind: .smartMagnify, phase: phase)
        case .beginGesture:
            return PortableGesture(kind: .begin, phase: .began)
        case .endGesture:
            return PortableGesture(kind: .end, phase: .ended)
        case .gesture:
            return PortableGesture(kind: .other, phase: phase)
        default:
            return nil
        }
    }

    private static func portablePhase(_ phase: NSEvent.Phase) -> PortableGesturePhase {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
        if phase.contains(.mayBegin) { return .mayBegin }
        return .none
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
