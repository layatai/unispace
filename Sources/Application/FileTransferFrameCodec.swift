import Foundation
import UniSpaceDomain

public enum FileTransferFrameCodec {
    public static let maximumEncodedSize = 2 * 1_024 * 1_024

    public static func encode(_ envelope: FileTransferEnvelope) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(envelope)
        guard data.count <= maximumEncodedSize else {
            throw FileTransferProtocolError.invalidChunkSize(data.count)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> FileTransferEnvelope {
        guard !data.isEmpty, data.count <= maximumEncodedSize else {
            throw FileTransferProtocolError.invalidChunkSize(data.count)
        }
        let envelope: FileTransferEnvelope
        do {
            envelope = try PropertyListDecoder().decode(FileTransferEnvelope.self, from: data)
        } catch {
            throw FileTransferProtocolError.malformedEnvelope
        }
        guard envelope.version == FileTransferEnvelope.protocolVersion else {
            throw FileTransferProtocolError.unsupportedVersion(envelope.version)
        }
        return envelope
    }
}
