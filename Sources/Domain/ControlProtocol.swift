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

public enum InputEvent: Codable, Equatable, Sendable {
    case pointerMove(deltaX: Double, deltaY: Double, absoluteX: Double, absoluteY: Double)
    case mouseButton(button: PointerButton, isDown: Bool, clickCount: Int)
    case scroll(deltaX: Double, deltaY: Double, isContinuous: Bool)
    case gesture(serializedEvent: Data)
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

public enum ControlMessage: Codable, Equatable, Sendable {
    case hello(DeviceDescriptor)
    case workspace(WorkspaceSnapshot)
    case controllerClaim(ControllerEpoch)
    case activate(InputActivation)
    case deactivate(SessionID)
    case heartbeat(sessionID: SessionID, timestampNanos: UInt64)
    case boundaryCrossed(sessionID: SessionID, displayID: DisplayID, edge: DisplayEdge, normalizedPosition: Double)
    case releaseAll(SessionID)
    case rotateWorkspaceKey(Data)
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
