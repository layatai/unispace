import CoreGraphics
import Foundation
import UniSpaceApplication
import UniSpaceDomain

public final class CGEventInputInjector: InputInjector, @unchecked Sendable {
    typealias DisplayBoundsProvider = @Sendable () -> [CGRect]
    typealias EventPoster = @Sendable (CGEvent) -> Void
    typealias CursorWarpHandler = @Sendable (CGPoint) -> Void

    public var pointerPositionHandler: (@Sendable (Double, Double) -> Void)?
    private let lock = NSLock()
    private let displayBoundsProvider: DisplayBoundsProvider
    private let eventPoster: EventPoster
    private let cursorWarpHandler: CursorWarpHandler
    private var displayBounds: [CGRect]
    private var cursorPosition = CGPoint.zero
    private var flags = CGEventFlags()
    private var pressedButtons: Set<PointerButton> = []
    private var pressedKeys: Set<UInt16> = []

    public convenience init() {
        self.init(
            displayBoundsProvider: Self.activeDisplayBounds,
            initialCursorPosition: CGEvent(source: nil)?.location ?? .zero,
            eventPoster: { $0.post(tap: .cgSessionEventTap) },
            cursorWarpHandler: { _ = CGWarpMouseCursorPosition($0) }
        )
    }

    init(
        displayBoundsProvider: @escaping DisplayBoundsProvider,
        initialCursorPosition: CGPoint = CGEvent(source: nil)?.location ?? .zero,
        eventPoster: @escaping EventPoster = { $0.post(tap: .cgSessionEventTap) },
        cursorWarpHandler: @escaping CursorWarpHandler = { _ = CGWarpMouseCursorPosition($0) }
    ) {
        self.displayBoundsProvider = displayBoundsProvider
        self.eventPoster = eventPoster
        self.cursorWarpHandler = cursorWarpHandler
        displayBounds = displayBoundsProvider()
        cursorPosition = initialCursorPosition
    }

    public func activate(on display: DisplayDescriptor, enteringFrom edge: DisplayEdge, normalizedPosition: Double) {
        let inset = 2.0
        let value = min(max(normalizedPosition, 0), 1)
        let frame = display.frame
        let point: CGPoint
        switch edge {
        case .left:
            point = CGPoint(x: frame.minX + inset, y: frame.minY + frame.height * value)
        case .right:
            point = CGPoint(x: frame.maxX - inset, y: frame.minY + frame.height * value)
        case .top:
            point = CGPoint(x: frame.minX + frame.width * value, y: frame.maxY - inset)
        case .bottom:
            point = CGPoint(x: frame.minX + frame.width * value, y: frame.minY + inset)
        }
        lock.lock()
        displayBounds = displayBoundsProvider()
        cursorPosition = Self.constrainedPosition(point, to: displayBounds)
        let activationPoint = cursorPosition
        lock.unlock()
        cursorWarpHandler(activationPoint)
    }

    public func inject(_ event: InputEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case let .pointerMove(deltaX, deltaY, _, _):
            cursorPosition.x += deltaX
            cursorPosition.y += deltaY
            cursorPosition = Self.constrainedPosition(cursorPosition, to: displayBounds)
            postMouse(type: dragEventType(), button: activeMouseButton(), position: cursorPosition, clickCount: 0)
            pointerPositionHandler?(cursorPosition.x, cursorPosition.y)
        case let .mouseButton(button, isDown, clickCount):
            if isDown { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
            postMouse(type: mouseEventType(button: button, isDown: isDown), button: cgButton(button), position: cursorPosition, clickCount: clickCount)
        case let .scroll(deltaX, deltaY, isContinuous):
            guard let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: isContinuous ? .pixel : .line,
                wheelCount: 2,
                wheel1: Int32(clamping: Int(deltaY.rounded())),
                wheel2: Int32(clamping: Int(deltaX.rounded())),
                wheel3: 0
            ) else { return }
            post(cgEvent)
        case let .gesture(serializedEvent, _):
            guard let cgEvent = Self.gestureEvent(from: serializedEvent, at: cursorPosition) else { return }
            post(cgEvent)
        case let .key(code, isDown, _):
            if isDown { pressedKeys.insert(code) } else { pressedKeys.remove(code) }
            guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: isDown) else { return }
            cgEvent.flags = flags
            post(cgEvent)
        case let .flags(rawValue):
            let previousFlags = flags
            let updatedFlags = CGEventFlags(rawValue: rawValue)
            flags = updatedFlags
            postModifierTransitions(from: previousFlags, to: updatedFlags)
        }
    }

    static func gestureEvent(from data: Data, at position: CGPoint) -> CGEvent? {
        guard let event = CGEvent(withDataAllocator: nil, data: data as CFData),
              CGEventInputCapture.gestureEventTypes.contains(where: {
                  $0.rawValue == event.type.rawValue
              }) else { return nil }
        event.location = position
        return event
    }

    static func constrainedPosition(_ position: CGPoint, to displayBounds: [CGRect]) -> CGPoint {
        guard !displayBounds.isEmpty,
              !displayBounds.contains(where: { $0.contains(position) }) else { return position }

        return displayBounds
            .map { bounds -> (CGPoint, CGFloat) in
                let candidate = CGPoint(
                    x: min(max(position.x, bounds.minX), bounds.maxX),
                    y: min(max(position.y, bounds.minY), bounds.maxY)
                )
                let distance = pow(candidate.x - position.x, 2) + pow(candidate.y - position.y, 2)
                return (candidate, distance)
            }
            .min(by: { $0.1 < $1.1 })?
            .0 ?? position
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }

    public func releaseAll() {
        lock.lock()
        let keys = pressedKeys
        let buttons = pressedButtons
        let activeFlags = flags
        pressedKeys.removeAll()
        pressedButtons.removeAll()
        flags = []
        lock.unlock()
        for key in keys {
            if let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(key),
                keyDown: false
            ) {
                event.flags = activeFlags
                post(event)
            }
        }
        postModifierTransitions(from: activeFlags, to: [])
        for button in buttons {
            postMouse(type: mouseEventType(button: button, isDown: false), button: cgButton(button), position: cursorPosition, clickCount: 1)
        }
    }

    private func postModifierTransitions(
        from previousFlags: CGEventFlags,
        to updatedFlags: CGEventFlags
    ) {
        for (mask, keyCode) in Self.modifierKeys {
            let wasPressed = previousFlags.contains(mask)
            let isPressed = updatedFlags.contains(mask)
            guard wasPressed != isPressed,
                  let event = CGEvent(
                      keyboardEventSource: nil,
                      virtualKey: keyCode,
                      keyDown: isPressed
                  ) else { continue }
            event.type = .flagsChanged
            event.flags = updatedFlags
            post(event)
        }
    }

    private static var modifierKeys: [(CGEventFlags, CGKeyCode)] {
        [
            (.maskCommand, 55),
            (.maskShift, 56),
            (.maskAlphaShift, 57),
            (.maskAlternate, 58),
            (.maskControl, 59),
            (.maskSecondaryFn, 63),
        ]
    }

    private func postMouse(type: CGEventType, button: CGMouseButton, position: CGPoint, clickCount: Int) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        post(event)
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: uniSpaceSyntheticEventMarker)
        eventPoster(event)
    }

    private func activeMouseButton() -> CGMouseButton {
        if pressedButtons.contains(.left) { return .left }
        if pressedButtons.contains(.right) { return .right }
        if pressedButtons.contains(.center) { return .center }
        return .left
    }

    private func dragEventType() -> CGEventType {
        if pressedButtons.contains(.left) { return .leftMouseDragged }
        if pressedButtons.contains(.right) { return .rightMouseDragged }
        if !pressedButtons.isEmpty { return .otherMouseDragged }
        return .mouseMoved
    }

    private func cgButton(_ button: PointerButton) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .center: .center
        case .other: CGMouseButton(rawValue: 3)!
        }
    }

    private func mouseEventType(button: PointerButton, isDown: Bool) -> CGEventType {
        switch (button, isDown) {
        case (.left, true): .leftMouseDown
        case (.left, false): .leftMouseUp
        case (.right, true): .rightMouseDown
        case (.right, false): .rightMouseUp
        case (_, true): .otherMouseDown
        case (_, false): .otherMouseUp
        }
    }
}
