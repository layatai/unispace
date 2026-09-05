import AppKit
import ApplicationServices
import Carbon
import ScreenCaptureKit
import UniSpaceDomain

/// Holds the exact, locally approved AX window. Never accepts a native handle
/// from a peer and never falls back to injecting into the current frontmost app.
@MainActor
public final class SeamlessWindowInput {
    private let window: AXUIElement
    private let application: AXUIElement
    private let process: pid_t
    private let approvedSize: CGSize
    private var keys = Set<CGKeyCode>()
    private var buttons = Set<UInt32>()
    private var lastPoint = CGPoint.zero

    public init(window captured: SCWindow) throws {
        guard AXIsProcessTrusted(), let owner = captured.owningApplication else {
            throw SeamlessWindowError.permissionDenied
        }
        process = owner.processID
        approvedSize = captured.frame.size
        application = AXUIElementCreateApplication(process)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { throw SeamlessWindowError.unavailable }
        let matches = windows.filter { item in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title)
            guard (title as? String ?? "") == (captured.title ?? ""), let rect = Self.frame(item) else { return false }
            return abs(rect.minX - captured.frame.minX) < 3 && abs(rect.minY - captured.frame.minY) < 3 &&
                abs(rect.width - captured.frame.width) < 3 && abs(rect.height - captured.frame.height) < 3
        }
        guard matches.count == 1 else { throw SeamlessWindowError.unavailable }
        window = matches[0]
    }

    public var isAvailable: Bool {
        guard !IsSecureEventInputEnabled(),
              NSRunningApplication(processIdentifier: process)?.isTerminated == false,
              let rect = Self.frame(window),
              abs(rect.width - approvedSize.width) < 3,
              abs(rect.height - approvedSize.height) < 3 else { return false }
        var minimized: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success else { return false }
        return minimized as? Bool != true
    }

    public func send(_ input: SeamlessInput) throws {
        try input.validate()
        if input.kind == .releaseAll { releaseAll(); return }
        guard isAvailable, let rect = Self.frame(window) else { throw SeamlessWindowError.unavailable }
        if input.kind == .leftDown || input.kind == .rightDown {
            NSRunningApplication(processIdentifier: process)?.activate(options: [])
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window)
        }
        // A menu/dialog or a local focus change must not redirect remote keys.
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFEqual(focused, window) else { releaseAll(); return }
        let point = CGPoint(x: rect.minX + input.x * max(0, rect.width - 1),
                            y: rect.minY + input.y * max(0, rect.height - 1))
        lastPoint = point
        let event: CGEvent?
        switch input.kind {
        case .keyDown, .keyUp:
            let down = input.kind == .keyDown
            if down { keys.insert(input.keyCode) } else { keys.remove(input.keyCode) }
            event = CGEvent(keyboardEventSource: nil, virtualKey: input.keyCode, keyDown: down)
        case .flagsChanged:
            event = CGEvent(keyboardEventSource: nil, virtualKey: input.keyCode, keyDown: false)
            event?.type = .flagsChanged
        case .scroll:
            event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: Int32(input.deltaY), wheel2: Int32(input.deltaX), wheel3: 0)
            event?.location = point
        default:
            let type: CGEventType
            let button: CGMouseButton
            switch input.kind {
            case .leftDown: type = .leftMouseDown; button = .left; buttons.insert(button.rawValue)
            case .leftUp: type = .leftMouseUp; button = .left; buttons.remove(button.rawValue)
            case .rightDown: type = .rightMouseDown; button = .right; buttons.insert(button.rawValue)
            case .rightUp: type = .rightMouseUp; button = .right; buttons.remove(button.rawValue)
            case .leftDrag: type = .leftMouseDragged; button = .left
            case .rightDrag: type = .rightMouseDragged; button = .right
            default: type = .mouseMoved; button = .left
            }
            event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        }
        event?.flags = CGEventFlags(rawValue: input.modifiers)
        post(event)
    }

    public func resize(width: Int, height: Int) throws {
        try SeamlessWindowDescriptor.validateSize(width: width, height: height)
        guard isAvailable else { throw SeamlessWindowError.unavailable }
        var size = CGSize(width: width, height: height)
        guard let value = AXValueCreate(.cgSize, &size),
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success else {
            throw SeamlessWindowError.unavailable
        }
    }

    public func releaseAll() {
        for key in keys { post(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)) }
        for raw in buttons {
            guard let button = CGMouseButton(rawValue: raw) else { continue }
            post(CGEvent(mouseEventSource: nil, mouseType: button == .left ? .leftMouseUp : .rightMouseUp,
                         mouseCursorPosition: lastPoint, mouseButton: button))
        }
        keys.removeAll(); buttons.removeAll()
        let flags = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: false)
        flags?.type = .flagsChanged; flags?.flags = []
        post(flags)
    }

    private func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: uniSpaceSyntheticEventMarker)
        event?.postToPid(process)
    }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
