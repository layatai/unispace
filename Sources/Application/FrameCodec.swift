import Foundation
import UniSpaceDomain

public enum WireFrameKind: UInt8, Sendable {
    case controlJSON = 1
    case inputBinary = 2
    case realtimePointerBinary = 3
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
