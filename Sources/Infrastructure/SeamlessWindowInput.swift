import AppKit
import ApplicationServices
import Carbon
import ScreenCaptureKit
import UniSpaceDomain
import UniSpaceApplication

/// Holds the exact, locally approved window. Never accepts a native handle
/// from a peer and never falls back to injecting into the current frontmost app.
///
/// Sandbox-safe: matches and tracks the window through CGWindowList and injects
/// through PID-targeted CGEvents. AX IPC is unusable here — the sandbox denies
/// mach-lookup com.apple.axserver (verified via sandboxd) — so this deliberately
/// uses no AX API at all.
/// ponytail: app-level (not window-level) focus gate; per-window focus needs AX.
@MainActor
public final class SeamlessWindowInput: SeamlessInputTarget {
    private let process: pid_t
    private let windowID: CGWindowID
    private let approvedFrame: CGRect
    private var keys = Set<CGKeyCode>()
    private var buttons = Set<UInt32>()
    private var lastPoint = CGPoint.zero

    public init(window captured: SCWindow) throws {
        guard let owner = captured.owningApplication else {
            throw SeamlessWindowError.permissionDenied
        }
        guard let match = Self.onScreenWindows(ownerPID: owner.processID).first(where: {
            Self.matches(capturedID: captured.windowID, capturedFrame: captured.frame,
                         listedID: $0.id, listedFrame: $0.frame)
        }) else {
            throw SeamlessWindowError.unavailable
        }
        process = owner.processID
        windowID = match.id
        approvedFrame = match.frame
    }

    public var isAvailable: Bool {
        guard !IsSecureEventInputEnabled(),
              NSRunningApplication(processIdentifier: process)?.isTerminated == false
        else { return false }
        // Minimized/closed windows leave the on-screen list; size drift ends input.
        return Self.onScreenWindows(ownerPID: process).contains {
            $0.id == windowID && $0.frame.sizeMatches(approvedFrame.size)
        }
    }

    public func send(_ input: SeamlessInput) throws {
        try input.validate()
        if input.kind == .releaseAll { releaseAll(); return }
        guard isAvailable,
              let bounds = Self.onScreenWindows(ownerPID: process).first(where: {
                  $0.id == windowID && $0.frame.sizeMatches(approvedFrame.size)
              })?.frame
        else { throw SeamlessWindowError.unavailable }
        let point = CGPoint(x: bounds.minX + input.x * max(0, bounds.width - 1),
                            y: bounds.minY + input.y * max(0, bounds.height - 1))
        // Keyboard events go straight to the target process regardless of
        // front/back state, but mouse events are still hit-tested against
        // real screen position — a click posted before activation actually
        // lands is swallowed by whatever's really on top. Only mouse-down
        // needs this; drags/up within the same gesture follow once active.
        if input.kind == .leftDown || input.kind == .rightDown {
            guard let application = NSRunningApplication(processIdentifier: process) else {
                throw SeamlessWindowError.unavailable
            }
            NSApp.yieldActivation(to: application)
            guard application.activate(options: [.activateAllWindows]) else {
                throw SeamlessWindowError.inputBlocked
            }
            let deadline = Date().addingTimeInterval(0.5)
            while (!application.isActive || Self.frontWindow(at: point) != windowID), Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            guard application.isActive else { throw SeamlessWindowError.inputBlocked }
        }
        // Both CG bounds and the normalized proxy picture use top-left origin.
        if input.kind == .leftDown || input.kind == .rightDown {
            guard isAvailable else { throw SeamlessWindowError.unavailable }
            guard Self.frontWindow(at: point) == windowID else {
                throw SeamlessWindowError.inputBlocked
            }
        }
        if (input.kind == .leftUp || input.kind == .leftDrag), !buttons.contains(CGMouseButton.left.rawValue) { return }
        if (input.kind == .rightUp || input.kind == .rightDrag), !buttons.contains(CGMouseButton.right.rawValue) { return }
        lastPoint = point
        // postToPid carries the event's own location, but doesn't move the
        // real cursor — some apps validate a click/drag against the actual
        // hardware position instead of trusting the event, so it's silently
        // dropped without this. The other remote-input path in this codebase
        // (CGEventInputInjector) already does this for the same reason.
        if input.kind != .keyDown, input.kind != .keyUp, input.kind != .flagsChanged {
            CGWarpMouseCursorPosition(point)
        }
        let event: CGEvent?
        switch input.kind {
        case .keyDown, .keyUp:
            let down = input.kind == .keyDown
            if down { keys.insert(input.keyCode) } else { keys.remove(input.keyCode) }
            event = CGEvent(keyboardEventSource: nil, virtualKey: input.keyCode, keyDown: down)
        case .flagsChanged:
            event = CGEvent(keyboardEventSource: nil, virtualKey: input.keyCode, keyDown: false)
            event?.type = .flagsChanged
            event?.flags = CGEventFlags(rawValue: input.modifiers)
            post(event)
            return
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
            if [.leftDown, .leftUp, .rightDown, .rightUp].contains(input.kind) {
                event?.setIntegerValueField(.mouseEventClickState, value: 1)
            }
        }
        event?.flags = CGEventFlags(rawValue: input.modifiers)
        post(event)
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
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: uniSpaceSyntheticEventMarker)
        if Self.postsThroughWindowServer(event.type) {
            event.post(tap: .cgSessionEventTap)
        } else {
            event.postToPid(process)
        }
    }

    static func postsThroughWindowServer(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .leftMouseDragged, .rightMouseDragged, .scrollWheel:
            true
        default:
            false
        }
    }

    static func matches(capturedID: CGWindowID, capturedFrame: CGRect,
                        listedID: CGWindowID, listedFrame: CGRect) -> Bool {
        capturedID == listedID && listedFrame.matches(capturedFrame)
    }

    private static func frontWindow(at point: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else { return nil }
        return frontWindow(at: point, in: list)
    }

    static func frontWindow(at point: CGPoint, in list: [[String: Any]]) -> CGWindowID? {
        return list.first(where: { item in
            guard let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return false }
            return rect.contains(point)
        })?[kCGWindowNumber as String] as? CGWindowID
    }

    private struct ListedWindow {
        let id: CGWindowID
        let frame: CGRect
    }

    private static func onScreenWindows(ownerPID: pid_t) -> [ListedWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == ownerPID,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"], w >= 16, h >= 16
            else { return nil }
            return ListedWindow(id: id, frame: CGRect(x: x, y: y, width: w, height: h))
        }
    }
}

private extension CGRect {
    /// SC frames may be in backing pixels while CG bounds are in points;
    /// accept 1x/2x/3x scale on size and origin together.
    func matches(_ other: CGRect) -> Bool {
        for scale: CGFloat in [1, 2, 3] {
            if abs(width - other.width * scale) < 3 * scale &&
                abs(height - other.height * scale) < 3 * scale &&
                abs(minX - other.minX * scale) < 3 * scale &&
                abs(minY - other.minY * scale) < 3 * scale { return true }
        }
        return false
    }

    func sizeMatches(_ other: CGSize) -> Bool {
        for scale: CGFloat in [1, 2, 3] {
            if abs(width - other.width * scale) < 3 * scale &&
                abs(height - other.height * scale) < 3 * scale { return true }
        }
        return false
    }
}
