import Foundation
import UniSpaceDomain

public enum WireFrameKind: UInt8, Sendable {
    case controlJSON = 1
    case inputBinary = 2
    case realtimePointerBinary = 3
    case controlJSONV2 = 4
    case inputBinaryV2 = 5
    case realtimePointerBinaryV2 = 6
}

public enum WireFrameCodec {
    public static let maximumPayloadSize = 1_048_576

    public static func encodeControl(_ envelope: ControlEnvelope) throws -> Data {
        var payload = try JSONEncoder.unispace.encode(envelope)
        return try frame(kind: .controlJSON, payload: &payload)
    }

    public static func encodeInput(_ frame: InputFrame) throws -> Data {
        var payload = try PropertyListEncoder.unispace.encode(frame)
        return try self.frame(kind: .inputBinary, payload: &payload)
    }

    public static func encodeRealtimePointer(_ frame: RealtimePointerFrame) throws -> Data {
        var payload = try PropertyListEncoder.unispace.encode(frame)
        return try self.frame(kind: .realtimePointerBinary, payload: &payload)
    }

    public static func encodePortableControl(_ envelope: ControlEnvelope) throws -> Data {
        var payload = try JSONEncoder.unispace.encode(PortableControlEnvelope(envelope))
        return try frame(kind: .controlJSONV2, payload: &payload)
    }

    public static func encodePortableInput(_ input: PortableInputFrame) throws -> Data {
        var payload = try PortableBinaryCodec.encode(input)
        return try frame(kind: .inputBinaryV2, payload: &payload)
    }

    public static func encodePortableRealtimePointer(_ input: PortableRealtimePointerFrame) throws -> Data {
        var payload = try PortableBinaryCodec.encode(input)
        return try frame(kind: .realtimePointerBinaryV2, payload: &payload)
    }

    public static func decode(_ data: Data) throws -> (WireFrameKind, Data) {
        guard data.count >= 5 else { throw ControlProtocolError.malformedFrame }
        let kindIndex = data.index(data.startIndex, offsetBy: 4)
        guard let kind = WireFrameKind(rawValue: data[kindIndex]) else {
            throw ControlProtocolError.malformedFrame
        }
        let declared = Int(data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard declared <= maximumPayloadSize else { throw ControlProtocolError.oversizedFrame(declared) }
        guard data.count == declared + 5 else { throw ControlProtocolError.malformedFrame }
        return (kind, Data(data.dropFirst(5)))
    }

    public static func decodeControl(_ payload: Data) throws -> ControlEnvelope {
        let envelope = try JSONDecoder().decode(ControlEnvelope.self, from: payload)
        guard envelope.version == ControlEnvelope.protocolVersion else {
            throw ControlProtocolError.unsupportedVersion(envelope.version)
        }
        return envelope
    }

    public static func decodeInput(_ payload: Data) throws -> InputFrame {
        try PropertyListDecoder().decode(InputFrame.self, from: payload)
    }

    public static func decodeRealtimePointer(_ payload: Data) throws -> RealtimePointerFrame {
        try PropertyListDecoder().decode(RealtimePointerFrame.self, from: payload)
    }

    public static func decodePortableControl(_ payload: Data) throws -> ControlEnvelope {
        let envelope = try JSONDecoder().decode(PortableControlEnvelope.self, from: payload)
        guard envelope.version == PortableControlEnvelope.protocolVersion else {
            throw ControlProtocolError.unsupportedVersion(envelope.version)
        }
        return try envelope.controlEnvelope()
    }

    public static func decodePortableInput(_ payload: Data) throws -> PortableInputFrame {
        try PortableBinaryCodec.decodeInput(payload)
    }

    public static func decodePortableRealtimePointer(_ payload: Data) throws -> PortableRealtimePointerFrame {
        try PortableBinaryCodec.decodeRealtimePointer(payload)
    }

    private static func frame(kind: WireFrameKind, payload: inout Data) throws -> Data {
        guard payload.count <= maximumPayloadSize else { throw ControlProtocolError.oversizedFrame(payload.count) }
        var result = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(kind.rawValue)
        result.append(payload)
        return result
    }
}

private struct PortableControlEnvelope: Codable {
    static let protocolVersion: UInt16 = 2

    let version: UInt16
    let type: String
    let payload: Payload

    struct Payload: Codable {
        var device: DeviceDescriptor? = nil
        var workspace: WorkspaceSnapshot? = nil
        var epoch: ControllerEpoch? = nil
        var activation: InputActivation? = nil
        var sessionID: SessionID? = nil
        var accepted: Bool? = nil
        var timestampNanos: UInt64? = nil
        var displayID: DisplayID? = nil
        var edge: DisplayEdge? = nil
        var normalizedPosition: Double? = nil
        var workspaceKey: Data? = nil
    }

    init(_ envelope: ControlEnvelope) {
        version = Self.protocolVersion
        switch envelope.message {
        case let .hello(device):
            type = "hello"
            payload = Payload(device: device)
        case let .workspace(workspace):
            type = "workspace"
            payload = Payload(workspace: workspace)
        case let .controllerClaim(epoch):
            type = "controllerClaim"
            payload = Payload(epoch: epoch)
        case let .activate(activation):
            type = "activate"
            payload = Payload(activation: activation)
        case let .activationResult(sessionID, accepted):
            type = "activationResult"
            payload = Payload(sessionID: sessionID, accepted: accepted)
        case let .deactivate(sessionID):
            type = "deactivate"
            payload = Payload(sessionID: sessionID)
        case let .heartbeat(sessionID, timestampNanos):
            type = "heartbeat"
            payload = Payload(sessionID: sessionID, timestampNanos: timestampNanos)
        case let .boundaryCrossed(sessionID, displayID, edge, normalizedPosition):
            type = "boundaryCrossed"
            payload = Payload(
                sessionID: sessionID,
                displayID: displayID,
                edge: edge,
                normalizedPosition: normalizedPosition
            )
        case let .releaseAll(sessionID):
            type = "releaseAll"
            payload = Payload(sessionID: sessionID)
        case let .rotateWorkspaceKey(workspaceKey):
            type = "rotateWorkspaceKey"
            payload = Payload(workspaceKey: workspaceKey)
        }
    }

    func controlEnvelope() throws -> ControlEnvelope {
        let message: ControlMessage
        switch type {
        case "hello":
            message = .hello(try required(payload.device))
        case "workspace":
            message = .workspace(try required(payload.workspace))
        case "controllerClaim":
            message = .controllerClaim(try required(payload.epoch))
        case "activate":
            message = .activate(try required(payload.activation))
        case "activationResult":
            message = .activationResult(
                sessionID: try required(payload.sessionID),
                accepted: try required(payload.accepted)
            )
        case "deactivate":
            message = .deactivate(try required(payload.sessionID))
        case "heartbeat":
            message = .heartbeat(
                sessionID: try required(payload.sessionID),
                timestampNanos: try required(payload.timestampNanos)
            )
        case "boundaryCrossed":
            message = .boundaryCrossed(
                sessionID: try required(payload.sessionID),
                displayID: try required(payload.displayID),
                edge: try required(payload.edge),
                normalizedPosition: try required(payload.normalizedPosition)
            )
        case "releaseAll":
            message = .releaseAll(try required(payload.sessionID))
        case "rotateWorkspaceKey":
            message = .rotateWorkspaceKey(try required(payload.workspaceKey))
        default:
            throw ControlProtocolError.malformedFrame
        }
        return ControlEnvelope(version: ControlEnvelope.protocolVersion, message: message)
    }

    private func required<T>(_ value: T?) throws -> T {
        guard let value else { throw ControlProtocolError.malformedFrame }
        return value
    }
}

private enum PortableBinaryCodec {
    private static let pointerMove: UInt8 = 1
    private static let mouseButton: UInt8 = 2
    private static let scroll: UInt8 = 3
    private static let key: UInt8 = 4
    private static let modifiers: UInt8 = 5
    private static let gesture: UInt8 = 6

    static func encode(_ frame: PortableInputFrame) throws -> Data {
        var writer = BinaryWriter()
        writer.append(PortableInputFrame.protocolVersion)
        writer.append(frame.workspaceID.rawValue)
        writer.append(frame.sessionID.rawValue)
        writer.append(frame.controllerID.rawValue)
        writer.append(frame.epoch.generation)
        writer.append(frame.epoch.controllerID.rawValue)
        writer.append(frame.sequence)
        writer.append(frame.timestampNanos)

        switch frame.event {
        case let .pointerMove(deltaX, deltaY, absoluteX, absoluteY):
            writer.append(pointerMove)
            writer.append(deltaX)
            writer.append(deltaY)
            writer.append(absoluteX)
            writer.append(absoluteY)
        case let .mouseButton(button, isDown, clickCount):
            writer.append(mouseButton)
            writer.append(button.rawValue)
            writer.append(isDown)
            writer.append(clickCount)
        case let .scroll(deltaX, deltaY, isContinuous):
            writer.append(scroll)
            writer.append(deltaX)
            writer.append(deltaY)
            writer.append(isContinuous)
        case let .key(usage, isDown, isRepeat):
            writer.append(key)
            writer.append(usage)
            writer.append(isDown)
            writer.append(isRepeat)
        case let .modifiers(mask):
            writer.append(modifiers)
            writer.append(mask.rawValue)
        case let .gesture(value):
            writer.append(gesture)
            writer.append(value.kind.rawValue)
            writer.append(value.phase.rawValue)
            writer.append(value.deltaX)
            writer.append(value.deltaY)
            writer.append(value.value)
        }
        return writer.data
    }

    static func decodeInput(_ data: Data) throws -> PortableInputFrame {
        var reader = BinaryReader(data)
        let version = try reader.readUInt16()
        guard version == PortableInputFrame.protocolVersion else {
            throw ControlProtocolError.unsupportedVersion(version)
        }
        let workspaceID = WorkspaceID(rawValue: try reader.readUUID())
        let sessionID = SessionID(rawValue: try reader.readUUID())
        let controllerID = DeviceID(rawValue: try reader.readUUID())
        let epoch = ControllerEpoch(
            generation: try reader.readUInt64(),
            controllerID: DeviceID(rawValue: try reader.readUUID())
        )
        let sequence = try reader.readUInt64()
        let timestampNanos = try reader.readUInt64()
        let eventType = try reader.readUInt8()
        let event: PortableInputEvent
        switch eventType {
        case pointerMove:
            event = .pointerMove(
                deltaX: try reader.readDouble(),
                deltaY: try reader.readDouble(),
                absoluteX: try reader.readDouble(),
                absoluteY: try reader.readDouble()
            )
        case mouseButton:
            guard let button = PointerButton(rawValue: try reader.readUInt8()) else {
                throw ControlProtocolError.malformedFrame
            }
            event = .mouseButton(
                button: button,
                isDown: try reader.readBool(),
                clickCount: try reader.readUInt16()
            )
        case scroll:
            event = .scroll(
                deltaX: try reader.readDouble(),
                deltaY: try reader.readDouble(),
                isContinuous: try reader.readBool()
            )
        case key:
            event = .key(
                usage: try reader.readUInt16(),
                isDown: try reader.readBool(),
                isRepeat: try reader.readBool()
            )
        case modifiers:
            event = .modifiers(PortableModifierMask(rawValue: try reader.readUInt16()))
        case gesture:
            guard let kind = PortableGestureKind(rawValue: try reader.readUInt8()),
                  let phase = PortableGesturePhase(rawValue: try reader.readUInt8()) else {
                throw ControlProtocolError.malformedFrame
            }
            event = .gesture(PortableGesture(
                kind: kind,
                phase: phase,
                deltaX: try reader.readDouble(),
                deltaY: try reader.readDouble(),
                value: try reader.readDouble()
            ))
        default:
            throw ControlProtocolError.malformedFrame
        }
        try reader.requireEnd()
        return PortableInputFrame(
            workspaceID: workspaceID,
            sessionID: sessionID,
            controllerID: controllerID,
            epoch: epoch,
            sequence: sequence,
            timestampNanos: timestampNanos,
            event: event
        )
    }

    static func encode(_ frame: PortableRealtimePointerFrame) throws -> Data {
        var writer = BinaryWriter()
        writer.append(PortableRealtimePointerFrame.protocolVersion)
        writer.append(frame.workspaceID.rawValue)
        writer.append(frame.sessionID.rawValue)
        writer.append(frame.controllerID.rawValue)
        writer.append(frame.epoch.generation)
        writer.append(frame.epoch.controllerID.rawValue)
        writer.append(frame.generation)
        writer.append(frame.sequence)
        writer.append(frame.timestampNanos)
        writer.append(frame.deltaX)
        writer.append(frame.deltaY)
        writer.append(frame.cumulativeDeltaX)
        writer.append(frame.cumulativeDeltaY)
        writer.append(frame.absoluteX)
        writer.append(frame.absoluteY)
        return writer.data
    }

    static func decodeRealtimePointer(_ data: Data) throws -> PortableRealtimePointerFrame {
        var reader = BinaryReader(data)
        let version = try reader.readUInt16()
        guard version == PortableRealtimePointerFrame.protocolVersion else {
            throw ControlProtocolError.unsupportedVersion(version)
        }
        let workspaceID = WorkspaceID(rawValue: try reader.readUUID())
        let sessionID = SessionID(rawValue: try reader.readUUID())
        let controllerID = DeviceID(rawValue: try reader.readUUID())
        let epoch = ControllerEpoch(
            generation: try reader.readUInt64(),
            controllerID: DeviceID(rawValue: try reader.readUUID())
        )
        let generation = try reader.readUInt64()
        let sequence = try reader.readUInt64()
        let timestampNanos = try reader.readUInt64()
        let frame = PortableRealtimePointerFrame(
            workspaceID: workspaceID,
            sessionID: sessionID,
            controllerID: controllerID,
            epoch: epoch,
            generation: generation,
            sequence: sequence,
            deltaX: try reader.readDouble(),
            deltaY: try reader.readDouble(),
            cumulativeDeltaX: try reader.readDouble(),
            cumulativeDeltaY: try reader.readDouble(),
            absoluteX: try reader.readDouble(),
            absoluteY: try reader.readDouble(),
            timestampNanos: timestampNanos
        )
        try reader.requireEnd()
        return frame
    }
}

private struct BinaryWriter {
    private(set) var data = Data()

    mutating func append(_ value: UInt8) { data.append(value) }
    mutating func append(_ value: Bool) { data.append(value ? 1 : 0) }
    mutating func append(_ value: UInt16) { appendFixedWidth(value.bigEndian) }
    mutating func append(_ value: UInt64) { appendFixedWidth(value.bigEndian) }
    mutating func append(_ value: Double) { append(value.bitPattern) }

    mutating func append(_ value: UUID) {
        var bytes = value.uuid
        Swift.withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
    }

    private mutating func appendFixedWidth<T>(_ value: T) {
        var value = value
        Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}

private struct BinaryReader {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func readUInt8() throws -> UInt8 {
        let bytes = try read(count: 1)
        return bytes[bytes.startIndex]
    }

    mutating func readBool() throws -> Bool {
        switch try readUInt8() {
        case 0: false
        case 1: true
        default: throw ControlProtocolError.malformedFrame
        }
    }

    mutating func readUInt16() throws -> UInt16 {
        try read(count: 2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        try read(count: 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    mutating func readUUID() throws -> UUID {
        let bytes = try read(count: 16)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard let uuid = UUID(uuidString: value) else { throw ControlProtocolError.malformedFrame }
        return uuid
    }

    mutating func requireEnd() throws {
        guard offset == data.count else { throw ControlProtocolError.malformedFrame }
    }

    private mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw ControlProtocolError.malformedFrame
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return data[start..<end]
    }
}

private extension JSONEncoder {
    static var unispace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension PropertyListEncoder {
    static var unispace: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
