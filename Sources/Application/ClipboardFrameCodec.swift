import Foundation
import UniSpaceDomain

/// Portable framing shared by the Swift and .NET clipboard implementations.
/// The fixed header is version, message kind, workspace UUID, sender UUID,
/// and payload length. The payload is canonical JSON and is encrypted by the
/// dedicated clipboard transport before it reaches the network.
public enum ClipboardFrameCodec {
    public static let headerSize = 2 + 1 + 16 + 16 + 4
    public static let maximumEncodedSize = 600 * 1_024
    private static let updateKind: UInt8 = 1

    public static func encode(_ envelope: ClipboardEnvelope) throws -> Data {
        guard envelope.version == ClipboardEnvelope.protocolVersion else {
            throw ClipboardProtocolError.unsupportedVersion(envelope.version)
        }
        try envelope.payload.validated()
        let payload = try jsonEncoder.encode(envelope.payload)
        guard payload.count <= maximumEncodedSize - headerSize else {
            throw ClipboardProtocolError.payloadTooLarge(payload.count)
        }

        var result = Data()
        result.reserveCapacity(headerSize + payload.count)
        result.appendClipboardUInt16(envelope.version)
        result.append(updateKind)
        result.appendClipboardUUID(envelope.workspaceID.rawValue)
        result.appendClipboardUUID(envelope.senderDeviceID.rawValue)
        result.appendClipboardUInt32(UInt32(payload.count))
        result.append(payload)
        return result
    }

    public static func decode(_ data: Data) throws -> ClipboardEnvelope {
        guard data.count >= headerSize, data.count <= maximumEncodedSize else {
            throw ClipboardProtocolError.malformedEnvelope
        }
        var reader = ClipboardFrameReader(data)
        let version = try reader.readUInt16()
        guard version == ClipboardEnvelope.protocolVersion else {
            throw ClipboardProtocolError.unsupportedVersion(version)
        }
        guard try reader.readUInt8() == updateKind else {
            throw ClipboardProtocolError.malformedEnvelope
        }
        let workspaceID = WorkspaceID(rawValue: try reader.readUUID())
        let senderDeviceID = DeviceID(rawValue: try reader.readUUID())
        let payloadLength = Int(try reader.readUInt32())
        guard payloadLength == reader.remainingCount else {
            throw ClipboardProtocolError.malformedEnvelope
        }
        let payloadData = try reader.readData(count: payloadLength)
        try reader.ensureEnd()

        let payload: ClipboardPayload
        do {
            payload = try jsonDecoder.decode(ClipboardPayload.self, from: payloadData)
        } catch {
            throw ClipboardProtocolError.malformedEnvelope
        }
        try payload.validated()
        return ClipboardEnvelope(
            version: version,
            workspaceID: workspaceID,
            senderDeviceID: senderDeviceID,
            payload: payload
        )
    }

    private static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct ClipboardFrameReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) { self.data = data }

    var remainingCount: Int { data.count - offset }

    mutating func readUInt8() throws -> UInt8 {
        try readData(count: 1)[0]
    }

    mutating func readUInt16() throws -> UInt16 {
        try readData(count: 2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        try readData(count: 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUUID() throws -> UUID {
        let bytes = [UInt8](try readData(count: 16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw ClipboardProtocolError.malformedEnvelope
        }
        let range = offset..<(offset + count)
        offset += count
        return data.subdata(in: range)
    }

    func ensureEnd() throws {
        guard offset == data.count else { throw ClipboardProtocolError.malformedEnvelope }
    }
}

private extension Data {
    mutating func appendClipboardUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendClipboardUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendClipboardUUID(_ value: UUID) {
        var uuid = value.uuid
        Swift.withUnsafeBytes(of: &uuid) { append(contentsOf: $0) }
    }
}
