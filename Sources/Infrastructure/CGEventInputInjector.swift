import CoreGraphics
import Foundation
import UniSpaceApplication
import UniSpaceDomain

public final class CGEventInputInjector: InputInjector, @unchecked Sendable {
    public var pointerPositionHandler: (@Sendable (Double, Double) -> Void)?
    private let lock = NSLock()
    private var cursorPosition = CGPoint.zero
    private var flags = CGEventFlags()
    private var pressedButtons: Set<PointerButton> = []
    private var pressedKeys: Set<UInt16> = []

    public init() {
        cursorPosition = CGEvent(source: nil)?.location ?? .zero
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
        cursorPosition = point
        lock.unlock()
        CGWarpMouseCursorPosition(point)
    }

    public func inject(_ event: InputEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case let .pointerMove(deltaX, deltaY, _, _):
            cursorPosition.x += deltaX
            cursorPosition.y += deltaY
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
        case let .key(code, isDown, _):
            if isDown { pressedKeys.insert(code) } else { pressedKeys.remove(code) }
            guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: isDown) else { return }
            cgEvent.flags = flags
            post(cgEvent)
        case let .flags(rawValue):
            flags = CGEventFlags(rawValue: rawValue)
        }
    }

    public func releaseAll() {
        lock.lock()
        let keys = pressedKeys
        let buttons = pressedButtons
        pressedKeys.removeAll()
        pressedButtons.removeAll()
        flags = []
        lock.unlock()
        for key in keys {
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: false) { post(event) }
        }
        for button in buttons {
            postMouse(type: mouseEventType(button: button, isDown: false), button: cgButton(button), position: cursorPosition, clickCount: 1)
        }
    }

    private func postMouse(type: CGEventType, button: CGMouseButton, position: CGPoint, clickCount: Int) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        post(event)
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: uniSpaceSyntheticEventMarker)
        event.post(tap: .cgSessionEventTap)
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
