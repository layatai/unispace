import Foundation

public struct ControllerEpoch: Codable, Hashable, Comparable, Sendable {
    public let generation: UInt64
    public let controllerID: DeviceID

    public init(generation: UInt64, controllerID: DeviceID) {
        self.generation = generation
        self.controllerID = controllerID
    }

    public static func < (lhs: ControllerEpoch, rhs: ControllerEpoch) -> Bool {
        if lhs.generation != rhs.generation {
            return lhs.generation < rhs.generation
        }
        return lhs.controllerID < rhs.controllerID
    }
}

public enum PointerButton: UInt8, Codable, CaseIterable, Hashable, Sendable {
    case left = 0
    case right = 1
    case center = 2
    case other = 3
}

public enum PortableGestureKind: UInt8, Codable, CaseIterable, Sendable {
    case other = 0
    case magnify = 1
    case swipe = 2
    case rotate = 3
    case smartMagnify = 4
    case begin = 5
    case end = 6
    case workspaceSwipe = 7
    case desktopPinch = 8
}

public enum PortableGesturePhase: UInt8, Codable, CaseIterable, Sendable {
    case none = 0
    case mayBegin = 1
    case began = 2
    case changed = 3
    case ended = 4
    case cancelled = 5
}

public struct PortableGesture: Codable, Equatable, Sendable {
    public let kind: PortableGestureKind
    public let phase: PortableGesturePhase
    public let deltaX: Double
    public let deltaY: Double
    public let value: Double

    public init(
        kind: PortableGestureKind,
        phase: PortableGesturePhase = .none,
        deltaX: Double = 0,
        deltaY: Double = 0,
        value: Double = 0
    ) {
        self.kind = kind
        self.phase = phase
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.value = value
    }
}

public enum InputEvent: Codable, Equatable, Sendable {
    case pointerMove(deltaX: Double, deltaY: Double, absoluteX: Double, absoluteY: Double)
    case mouseButton(button: PointerButton, isDown: Bool, clickCount: Int)
    case scroll(deltaX: Double, deltaY: Double, isContinuous: Bool)
    case gesture(serializedEvent: Data, portable: PortableGesture? = nil)
    case key(code: UInt16, isDown: Bool, isRepeat: Bool)
    case flags(rawValue: UInt64)
}

public struct InputFrame: Codable, Equatable, Sendable {
    public static let protocolVersion: UInt16 = 1

    public let workspaceID: WorkspaceID
    public let sessionID: SessionID
    public let controllerID: DeviceID
    public let epoch: ControllerEpoch
    public let sequence: UInt64
    public let timestampNanos: UInt64
    public let event: InputEvent

    public init(
        workspaceID: WorkspaceID,
        sessionID: SessionID,
        controllerID: DeviceID,
        epoch: ControllerEpoch,
        sequence: UInt64,
        timestampNanos: UInt64,
        event: InputEvent
    ) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.controllerID = controllerID
        self.epoch = epoch
        self.sequence = sequence
        self.timestampNanos = timestampNanos
        self.event = event
    }
}

/// Replaceable pointer state sent over the low-latency datagram lane.
/// Cumulative displacement lets the receiver recover motion represented by a lost datagram.
public struct RealtimePointerFrame: Codable, Equatable, Sendable {
    public static let protocolVersion: UInt16 = 1

    public let workspaceID: WorkspaceID
    public let sessionID: SessionID
    public let controllerID: DeviceID
    public let epoch: ControllerEpoch
    public let generation: UInt64
    public let sequence: UInt64
    public let deltaX: Double
    public let deltaY: Double
    public let cumulativeDeltaX: Double
    public let cumulativeDeltaY: Double
    public let absoluteX: Double
    public let absoluteY: Double
    public let timestampNanos: UInt64

    public init(
        workspaceID: WorkspaceID,
        sessionID: SessionID,
        controllerID: DeviceID,
        epoch: ControllerEpoch,
        generation: UInt64,
        sequence: UInt64,
        deltaX: Double,
        deltaY: Double,
        cumulativeDeltaX: Double,
        cumulativeDeltaY: Double,
        absoluteX: Double,
        absoluteY: Double,
        timestampNanos: UInt64
    ) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.controllerID = controllerID
        self.epoch = epoch
        self.generation = generation
        self.sequence = sequence
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.cumulativeDeltaX = cumulativeDeltaX
        self.cumulativeDeltaY = cumulativeDeltaY
        self.absoluteX = absoluteX
        self.absoluteY = absoluteY
        self.timestampNanos = timestampNanos
    }

    public var reliableFallback: InputFrame {
        InputFrame(
            workspaceID: workspaceID,
            sessionID: sessionID,
            controllerID: controllerID,
            epoch: epoch,
            sequence: sequence,
            timestampNanos: timestampNanos,
            event: .pointerMove(
                deltaX: deltaX,
                deltaY: deltaY,
                absoluteX: absoluteX,
                absoluteY: absoluteY
            )
        )
    }
}

public struct RealtimePointerProgress: Codable, Equatable, Sendable {
    public let sessionID: SessionID
    public let generation: UInt64
    public let sequence: UInt64

    public init(sessionID: SessionID, generation: UInt64, sequence: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
        self.sequence = sequence
    }
}

public struct InputActivation: Codable, Equatable, Sendable {
    public let sessionID: SessionID
    public let epoch: ControllerEpoch
    public let targetDisplayID: DisplayID
    public let entryEdge: DisplayEdge
    public let normalizedPosition: Double

    public init(
        sessionID: SessionID,
        epoch: ControllerEpoch,
        targetDisplayID: DisplayID,
        entryEdge: DisplayEdge,
        normalizedPosition: Double
    ) {
        self.sessionID = sessionID
        self.epoch = epoch
        self.targetDisplayID = targetDisplayID
        self.entryEdge = entryEdge
        self.normalizedPosition = min(max(normalizedPosition, 0), 1)
    }
}

public struct WorkspacePresenceSnapshot: Codable, Equatable, Sendable {
    public let epoch: ControllerEpoch
    public let onlineDeviceIDs: Set<DeviceID>

    public init(epoch: ControllerEpoch, onlineDeviceIDs: Set<DeviceID>) {
        self.epoch = epoch
        self.onlineDeviceIDs = onlineDeviceIDs
    }

    public func validatedOnlineDeviceIDs(
        from source: DeviceID,
        currentEpoch: ControllerEpoch?,
        workspace: WorkspaceSnapshot
    ) -> Set<DeviceID>? {
        guard source == epoch.controllerID, currentEpoch == epoch else { return nil }
        return onlineDeviceIDs.intersection(Set(workspace.devices.map(\.id)))
    }
}

public enum ControlMessage: Codable, Equatable, Sendable {
    case hello(DeviceDescriptor)
    case workspace(WorkspaceSnapshot)
    case controllerClaim(ControllerEpoch)
    case activate(InputActivation)
    case activationResult(sessionID: SessionID, accepted: Bool)
    case deactivate(SessionID)
    case heartbeat(sessionID: SessionID, timestampNanos: UInt64)
    case realtimePointerProgress(RealtimePointerProgress)
    case boundaryCrossed(sessionID: SessionID, displayID: DisplayID, edge: DisplayEdge, normalizedPosition: Double)
    case releaseAll(SessionID)
    case rotateWorkspaceKey(Data)
    case workspacePresence(WorkspacePresenceSnapshot)
}

public struct ControlEnvelope: Codable, Equatable, Sendable {
    public static let protocolVersion: UInt16 = 1
    public let version: UInt16
    public let message: ControlMessage

    public init(version: UInt16 = Self.protocolVersion, message: ControlMessage) {
        self.version = version
        self.message = message
    }
}

public enum ControlProtocolError: Error, Equatable {
    case unsupportedVersion(UInt16)
    case malformedFrame
    case oversizedFrame(Int)
}

public struct PortableModifierMask: OptionSet, Equatable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let shift = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
    public static let capsLock = Self(rawValue: 1 << 4)
    public static let function = Self(rawValue: 1 << 5)
}

public enum PortableInputEvent: Equatable, Sendable {
    case pointerMove(deltaX: Double, deltaY: Double, absoluteX: Double, absoluteY: Double)
    case mouseButton(button: PointerButton, isDown: Bool, clickCount: UInt16)
    case scroll(deltaX: Double, deltaY: Double, isContinuous: Bool)
    case key(usage: UInt16, isDown: Bool, isRepeat: Bool)
    case modifiers(PortableModifierMask)
    case gesture(PortableGesture)
}

public struct PortableInputFrame: Equatable, Sendable {
    public static let protocolVersion: UInt16 = 2

    public let workspaceID: WorkspaceID
    public let sessionID: SessionID
    public let controllerID: DeviceID
    public let epoch: ControllerEpoch
    public let sequence: UInt64
    public let timestampNanos: UInt64
    public let event: PortableInputEvent

    public init(
        workspaceID: WorkspaceID,
        sessionID: SessionID,
        controllerID: DeviceID,
        epoch: ControllerEpoch,
        sequence: UInt64,
        timestampNanos: UInt64,
        event: PortableInputEvent
    ) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.controllerID = controllerID
        self.epoch = epoch
        self.sequence = sequence
        self.timestampNanos = timestampNanos
        self.event = event
    }
}

/// Replaceable pointer state for the authenticated cross-platform UDP lane.
/// The cumulative displacement lets receivers recover motion lost between datagrams.
public struct PortableRealtimePointerFrame: Equatable, Sendable {
    public static let protocolVersion: UInt16 = 2

    public let workspaceID: WorkspaceID
    public let sessionID: SessionID
    public let controllerID: DeviceID
    public let epoch: ControllerEpoch
    public let generation: UInt64
    public let sequence: UInt64
    public let deltaX: Double
    public let deltaY: Double
    public let cumulativeDeltaX: Double
    public let cumulativeDeltaY: Double
    public let absoluteX: Double
    public let absoluteY: Double
    public let timestampNanos: UInt64

    public init(
        workspaceID: WorkspaceID,
        sessionID: SessionID,
        controllerID: DeviceID,
        epoch: ControllerEpoch,
        generation: UInt64,
        sequence: UInt64,
        deltaX: Double,
        deltaY: Double,
        cumulativeDeltaX: Double,
        cumulativeDeltaY: Double,
        absoluteX: Double,
        absoluteY: Double,
        timestampNanos: UInt64
    ) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.controllerID = controllerID
        self.epoch = epoch
        self.generation = generation
        self.sequence = sequence
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.cumulativeDeltaX = cumulativeDeltaX
        self.cumulativeDeltaY = cumulativeDeltaY
        self.absoluteX = absoluteX
        self.absoluteY = absoluteY
        self.timestampNanos = timestampNanos
    }

    public var reliableFallback: PortableInputFrame {
        PortableInputFrame(
            workspaceID: workspaceID,
            sessionID: sessionID,
            controllerID: controllerID,
            epoch: epoch,
            sequence: sequence,
            timestampNanos: timestampNanos,
            event: .pointerMove(
                deltaX: deltaX,
                deltaY: deltaY,
                absoluteX: absoluteX,
                absoluteY: absoluteY
            )
        )
    }
}
