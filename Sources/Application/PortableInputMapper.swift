import Foundation
import UniSpaceDomain

public enum PortableInputMapper {
    public static func map(_ frame: InputFrame) -> PortableInputFrame? {
        guard let event = map(frame.event) else { return nil }
        return PortableInputFrame(
            workspaceID: frame.workspaceID,
            sessionID: frame.sessionID,
            controllerID: frame.controllerID,
            epoch: frame.epoch,
            sequence: frame.sequence,
            timestampNanos: frame.timestampNanos,
            event: event
        )
    }

    public static func map(_ frame: RealtimePointerFrame) -> PortableRealtimePointerFrame {
        PortableRealtimePointerFrame(
            workspaceID: frame.workspaceID,
            sessionID: frame.sessionID,
            controllerID: frame.controllerID,
            epoch: frame.epoch,
            generation: frame.generation,
            sequence: frame.sequence,
            deltaX: frame.deltaX,
            deltaY: frame.deltaY,
            cumulativeDeltaX: frame.cumulativeDeltaX,
            cumulativeDeltaY: frame.cumulativeDeltaY,
            absoluteX: frame.absoluteX,
            absoluteY: frame.absoluteY,
            timestampNanos: frame.timestampNanos
        )
    }

    public static func map(_ event: InputEvent) -> PortableInputEvent? {
        switch event {
        case let .pointerMove(deltaX, deltaY, absoluteX, absoluteY):
            .pointerMove(deltaX: deltaX, deltaY: deltaY, absoluteX: absoluteX, absoluteY: absoluteY)
        case let .mouseButton(button, isDown, clickCount):
            .mouseButton(
                button: button,
                isDown: isDown,
                clickCount: UInt16(clamping: clickCount)
            )
        case let .scroll(deltaX, deltaY, isContinuous):
            .scroll(deltaX: deltaX, deltaY: deltaY, isContinuous: isContinuous)
        case .gesture:
            nil
        case let .key(code, isDown, isRepeat):
            keyCodeToHIDUsage[code].map { .key(usage: $0, isDown: isDown, isRepeat: isRepeat) }
        case let .flags(rawValue):
            .modifiers(modifierMask(rawFlags: rawValue))
        }
    }

    public static func modifierMask(rawFlags: UInt64) -> PortableModifierMask {
        var result: PortableModifierMask = []
        if rawFlags & 0x0002_0000 != 0 { result.insert(.shift) }
        if rawFlags & 0x0004_0000 != 0 { result.insert(.control) }
        if rawFlags & 0x0008_0000 != 0 { result.insert(.option) }
        if rawFlags & 0x0010_0000 != 0 { result.insert(.command) }
        if rawFlags & 0x0001_0000 != 0 { result.insert(.capsLock) }
        if rawFlags & 0x0080_0000 != 0 { result.insert(.function) }
        return result
    }

    /// Apple virtual key codes mapped to USB HID Keyboard/Keypad page usages.
    public static let keyCodeToHIDUsage: [UInt16: UInt16] = [
        0: 0x04, 1: 0x16, 2: 0x07, 3: 0x09, 4: 0x0B, 5: 0x0A,
        6: 0x1D, 7: 0x1B, 8: 0x06, 9: 0x19, 11: 0x05, 12: 0x14,
        13: 0x1A, 14: 0x08, 15: 0x15, 16: 0x1C, 17: 0x17,
        18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 22: 0x23, 23: 0x22,
        24: 0x2E, 25: 0x26, 26: 0x24, 27: 0x2D, 28: 0x25, 29: 0x27,
        30: 0x30, 31: 0x12, 32: 0x18, 33: 0x2F, 34: 0x0C, 35: 0x13, 36: 0x28,
        37: 0x0F, 38: 0x0D, 39: 0x34, 40: 0x0E, 41: 0x33, 42: 0x31,
        43: 0x36, 44: 0x38, 45: 0x11, 46: 0x10, 47: 0x37, 48: 0x2B,
        49: 0x2C, 50: 0x35, 51: 0x2A, 53: 0x29,
        65: 0x63, 67: 0x55, 69: 0x57, 71: 0x53, 75: 0x54, 76: 0x58,
        78: 0x56, 81: 0x67, 82: 0x62, 83: 0x59, 84: 0x5A, 85: 0x5B,
        86: 0x5C, 87: 0x5D, 88: 0x5E, 89: 0x5F, 91: 0x60, 92: 0x61,
        96: 0x3E, 97: 0x3F, 98: 0x40, 99: 0x3C, 100: 0x41,
        101: 0x42, 103: 0x44, 105: 0x68, 106: 0x6B, 107: 0x69,
        109: 0x43, 111: 0x45, 113: 0x6A, 114: 0x49, 115: 0x4A,
        116: 0x4B, 117: 0x4C, 118: 0x3D, 119: 0x4D, 120: 0x3B,
        121: 0x4E, 122: 0x3A, 123: 0x50, 124: 0x4F, 125: 0x51, 126: 0x52,
    ]
}
