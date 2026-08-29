import Foundation
import UniSpaceDomain

/// Portable file-transfer framing shared by the Swift and .NET implementations.
///
/// Every frame starts with a fixed big-endian header:
/// version (UInt16), message kind (UInt8), workspace UUID (16 bytes), sender UUID
/// (16 bytes), and payload length (UInt32). Metadata payloads are JSON. Chunk
/// payloads remain binary so a 1 MiB chunk never incurs base64 expansion.
public enum FileTransferFrameCodec {
    public static let maximumEncodedSize = 2 * 1_024 * 1_024
    public static let headerSize = 2 + 1 + 16 + 16 + 4

    public enum MessageKind: UInt8, CaseIterable, Sendable {
        case offer = 1
        case request = 2
        case chunk = 3
        case acknowledgement = 4
        case entryComplete = 5
        case transferComplete = 6
        case verification = 7
        case cancellation = 8
        case resumeQuery = 9
        case resumeState = 10
        case failure = 11
    }

    public static func encode(_ envelope: FileTransferEnvelope) throws -> Data {
        guard envelope.version == FileTransferEnvelope.protocolVersion else {
            throw FileTransferProtocolError.unsupportedVersion(envelope.version)
        }
        let encoded = try encodeMessage(envelope.message)
        guard encoded.payload.count <= maximumEncodedSize - headerSize else {
            throw FileTransferProtocolError.invalidChunkSize(encoded.payload.count)
        }

        var result = Data()
        result.reserveCapacity(headerSize + encoded.payload.count)
        result.appendUInt16(envelope.version)
        result.append(encoded.kind.rawValue)
        result.appendUUID(envelope.workspaceID.rawValue)
        result.appendUUID(envelope.senderDeviceID.rawValue)
        result.appendUInt32(UInt32(encoded.payload.count))
        result.append(encoded.payload)
        return result
    }

    public static func decode(_ data: Data) throws -> FileTransferEnvelope {
        guard data.count >= headerSize, data.count <= maximumEncodedSize else {
            throw FileTransferProtocolError.invalidChunkSize(data.count)
        }
        var reader = PortableTransferReader(data)
        let version = try reader.readUInt16()
        guard version == FileTransferEnvelope.protocolVersion else {
            throw FileTransferProtocolError.unsupportedVersion(version)
        }
        guard let kind = MessageKind(rawValue: try reader.readUInt8()) else {
            throw FileTransferProtocolError.malformedEnvelope
        }
        let workspaceID = WorkspaceID(rawValue: try reader.readUUID())
        let senderDeviceID = DeviceID(rawValue: try reader.readUUID())
        let payloadLength = Int(try reader.readUInt32())
        guard payloadLength == reader.remainingCount else {
            throw FileTransferProtocolError.malformedEnvelope
        }
        let payload = try reader.readData(count: payloadLength)
        try reader.ensureEnd()
        return FileTransferEnvelope(
            version: version,
            workspaceID: workspaceID,
            senderDeviceID: senderDeviceID,
            message: try decodeMessage(kind: kind, payload: payload)
        )
    }

    private static func encodeMessage(
        _ message: FileTransferMessage
    ) throws -> (kind: MessageKind, payload: Data) {
        switch message {
        case let .offer(value):
            return (.offer, try jsonEncoder.encode(value))
        case let .request(value):
            return (.request, try jsonEncoder.encode(value))
        case let .chunk(value):
            return (.chunk, try encodeChunk(value))
        case let .acknowledgement(value):
            return (.acknowledgement, try jsonEncoder.encode(value))
        case let .entryComplete(value):
            return (.entryComplete, try jsonEncoder.encode(value))
        case let .transferComplete(value):
            return (.transferComplete, try jsonEncoder.encode(value))
        case let .verification(value):
            return (.verification, try jsonEncoder.encode(value))
        case let .cancellation(value):
            return (.cancellation, try jsonEncoder.encode(value))
        case let .resumeQuery(value):
            return (.resumeQuery, try jsonEncoder.encode(value))
        case let .resumeState(value):
            return (.resumeState, try jsonEncoder.encode(value))
        case let .failure(value):
            return (.failure, try jsonEncoder.encode(value))
        }
    }

    private static func decodeMessage(
        kind: MessageKind,
        payload: Data
    ) throws -> FileTransferMessage {
        do {
            switch kind {
            case .offer:
                return .offer(try jsonDecoder.decode(TransferOffer.self, from: payload))
            case .request:
                return .request(try jsonDecoder.decode(TransferRequest.self, from: payload))
            case .chunk:
                return .chunk(try decodeChunk(payload))
            case .acknowledgement:
                return .acknowledgement(
                    try jsonDecoder.decode(TransferAcknowledgement.self, from: payload)
                )
            case .entryComplete:
                return .entryComplete(
                    try jsonDecoder.decode(TransferEntryCompletion.self, from: payload)
                )
            case .transferComplete:
                return .transferComplete(
                    try jsonDecoder.decode(TransferCompletion.self, from: payload)
                )
            case .verification:
                return .verification(
                    try jsonDecoder.decode(TransferVerification.self, from: payload)
                )
            case .cancellation:
                return .cancellation(
                    try jsonDecoder.decode(TransferCancellation.self, from: payload)
                )
            case .resumeQuery:
                return .resumeQuery(
                    try jsonDecoder.decode(TransferResumeQuery.self, from: payload)
                )
            case .resumeState:
                return .resumeState(
                    try jsonDecoder.decode(TransferResumeState.self, from: payload)
                )
            case .failure:
                return .failure(try jsonDecoder.decode(TransferFailure.self, from: payload))
            }
        } catch let error as FileTransferProtocolError {
            throw error
        } catch {
            throw FileTransferProtocolError.malformedEnvelope
        }
    }

    private static func encodeChunk(_ chunk: TransferChunk) throws -> Data {
        guard chunk.data.count <= FileTransferLimits.default.maximumChunkSize else {
            throw FileTransferProtocolError.invalidChunkSize(chunk.data.count)
        }
        var payload = Data()
        payload.reserveCapacity(16 + 16 + 8 + 4 + chunk.data.count)
        payload.appendUUID(chunk.transferID.rawValue)
        payload.appendUUID(chunk.entryID.rawValue)
        payload.appendUInt64(chunk.offset)
        payload.appendUInt32(UInt32(chunk.data.count))
        payload.append(chunk.data)
        return payload
    }

    private static func decodeChunk(_ payload: Data) throws -> TransferChunk {
        var reader = PortableTransferReader(payload)
        let transferID = TransferID(rawValue: try reader.readUUID())
        let entryID = TransferEntryID(rawValue: try reader.readUUID())
        let offset = try reader.readUInt64()
        let count = Int(try reader.readUInt32())
        guard count > 0,
              count <= FileTransferLimits.default.maximumChunkSize,
              count == reader.remainingCount else {
            throw FileTransferProtocolError.invalidChunkSize(count)
        }
        let bytes = try reader.readData(count: count)
        try reader.ensureEnd()
        return TransferChunk(
            transferID: transferID,
            entryID: entryID,
            offset: offset,
            data: bytes
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

private struct PortableTransferReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) {
        self.data = data
    }

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

    mutating func readUInt64() throws -> UInt64 {
        try readData(count: 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
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
            throw FileTransferProtocolError.malformedEnvelope
        }
        let range = offset..<(offset + count)
        offset += count
        return data.subdata(in: range)
    }

    func ensureEnd() throws {
        guard offset == data.count else {
            throw FileTransferProtocolError.malformedEnvelope
        }
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt64(_ value: UInt64) {
        append(UInt8(truncatingIfNeeded: value >> 56))
        append(UInt8(truncatingIfNeeded: value >> 48))
        append(UInt8(truncatingIfNeeded: value >> 40))
        append(UInt8(truncatingIfNeeded: value >> 32))
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUUID(_ value: UUID) {
        var uuid = value.uuid
        Swift.withUnsafeBytes(of: &uuid) { append(contentsOf: $0) }
    }
}
