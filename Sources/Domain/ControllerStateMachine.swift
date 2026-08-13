import Foundation

public struct ControllerStateMachine: Sendable {
    public private(set) var currentEpoch: ControllerEpoch?
    public private(set) var nextGeneration: UInt64

    public init(currentEpoch: ControllerEpoch? = nil, nextGeneration: UInt64 = 1) {
        self.currentEpoch = currentEpoch
        self.nextGeneration = max(nextGeneration, (currentEpoch?.generation ?? 0) + 1)
    }

    public mutating func claim(for deviceID: DeviceID) -> ControllerEpoch {
        let epoch = ControllerEpoch(generation: nextGeneration, controllerID: deviceID)
        nextGeneration += 1
        currentEpoch = epoch
        return epoch
    }

    @discardableResult
    public mutating func observe(_ candidate: ControllerEpoch) -> Bool {
        nextGeneration = max(nextGeneration, candidate.generation + 1)
        guard currentEpoch == nil || currentEpoch! < candidate else {
            return false
        }
        currentEpoch = candidate
        return true
    }

    public func accepts(_ frame: InputFrame) -> Bool {
        frame.controllerID == currentEpoch?.controllerID && frame.epoch == currentEpoch
    }
}

public struct RemoteInputState: Sendable, Equatable {
    public private(set) var pressedKeys: Set<UInt16> = []
    public private(set) var pressedButtons: Set<PointerButton> = []

    public init() {}

    public mutating func apply(_ event: InputEvent) {
        switch event {
        case let .key(code, isDown, _):
            if isDown { pressedKeys.insert(code) } else { pressedKeys.remove(code) }
        case let .mouseButton(button, isDown, _):
            if isDown { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
        case .pointerMove, .scroll, .gesture, .flags:
            break
        }
    }

    public mutating func releaseEvents() -> [InputEvent] {
        let keyReleases = pressedKeys.sorted().map { InputEvent.key(code: $0, isDown: false, isRepeat: false) }
        let buttonReleases = pressedButtons.sorted { $0.rawValue < $1.rawValue }.map {
            InputEvent.mouseButton(button: $0, isDown: false, clickCount: 1)
        }
        pressedKeys.removeAll()
        pressedButtons.removeAll()
        return keyReleases + buttonReleases
    }
}
