import Foundation
import UniSpaceDomain

/// Portable clipboard stream v2 payload. Metadata is UTF-8 JSON; range bytes
/// are binary. The surrounding authenticated content envelope binds the peer.
public enum ClipboardStreamCodec {
    public static let version: UInt16 = 2
    public static let maximumEncodedBytes = 2 * 1_024 * 1_024
    public enum Kind: UInt8, CaseIterable, Sendable {
        case announce = 1, withdraw, open, opened, read, range, finish, finished, close, error
    }
    public static func encode(_ message: ClipboardStreamMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let kind: Kind
        let payload: Data
        switch message {
        case let .announce(value): kind = .announce; payload = try encoder.encode(value)
        case let .withdraw(value): kind = .withdraw; payload = try encoder.encode(value)
        case let .open(value): kind = .open; payload = try encoder.encode(value)
        case let .opened(value): kind = .opened; payload = try encoder.encode(value)
        case let .read(value): kind = .read; payload = try encoder.encode(value)
        case let .range(value):
            kind = .range
            guard value.data.count <= ClipboardStreamLimits.default.maximumReadBytes else { throw ClipboardStreamFailure.invalidRequest }
            var bytes = Data()
            append(value.requestID, to: &bytes); append(value.leaseID, to: &bytes); append(value.fileID, to: &bytes)
            append(value.offset, to: &bytes)
            append(UInt32(value.data.count), to: &bytes)
            bytes.append(value.data)
            payload = bytes
        case let .finish(value): kind = .finish; payload = try encoder.encode(value)
        case let .finished(value): kind = .finished; payload = try encoder.encode(value)
        case let .close(value): kind = .close; payload = try encoder.encode(value)
        case let .error(value): kind = .error; payload = try encoder.encode(value)
        }
        guard payload.count <= maximumEncodedBytes - 3 else { throw ClipboardStreamFailure.invalidRequest }
        var result = Data([0, UInt8(version), kind.rawValue])
        result.append(payload)
        return result
    }
    public static func decode(_ data: Data) throws -> ClipboardStreamMessage {
        guard data.count >= 3, data.count <= maximumEncodedBytes,
              data[data.startIndex] == 0, data[data.startIndex + 1] == UInt8(version), let kind = Kind(rawValue: data[data.startIndex + 2]) else { throw ClipboardStreamFailure.invalidRequest }
        let payload = Data(data.dropFirst(3))
        let decoder = JSONDecoder()
        do {
            switch kind {
            case .announce: return .announce(try decoder.decode(ClipboardStreamSelection.self, from: payload))
            case .withdraw: return .withdraw(try decoder.decode(ClipboardStreamReference.self, from: payload))
            case .open: return .open(try decoder.decode(ClipboardStreamOpen.self, from: payload))
            case .opened: return .opened(try decoder.decode(ClipboardStreamLease.self, from: payload))
            case .read: return .read(try decoder.decode(ClipboardStreamRead.self, from: payload))
            case .range:
                var reader = RangeReader(data: payload)
                let requestID = try reader.uuid(); let leaseID = try reader.uuid(); let fileID = try reader.uuid()
                let offset: UInt64 = try reader.integer()
                let count: UInt32 = try reader.integer()
                guard count <= ClipboardStreamLimits.default.maximumReadBytes,
                      Int(count) == payload.count - reader.cursor else { throw ClipboardStreamFailure.invalidRequest }
                return .range(.init(requestID: requestID, leaseID: leaseID, fileID: fileID,
                                    offset: offset, data: Data(payload.dropFirst(reader.cursor))))
            case .finish: return .finish(try decoder.decode(ClipboardStreamFinish.self, from: payload))
            case .finished: return .finished(try decoder.decode(ClipboardStreamFinish.self, from: payload))
            case .close: return .close(try decoder.decode(ClipboardStreamReference.self, from: payload))
            case .error: return .error(try decoder.decode(ClipboardStreamError.self, from: payload))
            }
        } catch { throw ClipboardStreamFailure.invalidRequest }
    }
    private static func append(_ id: UUID, to data: inout Data) {
        var value = id.uuid
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
    private struct RangeReader {
        let data: Data
        var cursor = 0
        mutating func integer<T: FixedWidthInteger>() throws -> T {
            let count = MemoryLayout<T>.size
            guard count <= data.count - cursor else { throw ClipboardStreamFailure.invalidRequest }
            var result: T = 0
            for byte in data[cursor..<(cursor + count)] { result = (result << 8) | T(byte) }
            cursor += count
            return result
        }
        mutating func uuid() throws -> UUID {
            guard 16 <= data.count - cursor else { throw ClipboardStreamFailure.invalidRequest }
            let bytes = Array(data[cursor..<(cursor + 16)])
            cursor += 16
            return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        }
    }
}
