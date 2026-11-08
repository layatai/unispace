import Foundation
import Testing
@testable import UniSpaceApplication
import UniSpaceDomain

/// Pins ClipboardStreamCodec against the shared golden vectors in
/// Docs/golden/clipboard-stream-v2-vectors.json. Metadata frames are compared
/// semantically (Swift sorts JSON keys, C# uses declaration order); the binary
/// range frame is compared byte-for-byte.
struct ClipboardStreamGoldenVectorTests {
    @Test func frameHeaderAndKindMapMatchTheSharedVectors() throws {
        let file = try GoldenVectorFile.load()
        #expect(file.frameHeader == [0, 2])
        let kinds: [(String, ClipboardStreamCodec.Kind)] = [
            ("announce", .announce), ("withdraw", .withdraw), ("open", .open), ("opened", .opened),
            ("read", .read), ("range", .range), ("finish", .finish), ("finished", .finished),
            ("close", .close), ("error", .error),
        ]
        for (name, kind) in kinds { #expect(file.kinds[name] == Int(kind.rawValue)) }
    }

    @Test func metadataVectorsEncodeDecodeAndKeepCamelCaseKeys() throws {
        let file = try GoldenVectorFile.load()
        for vector in file.vectors {
            guard let payload = vector.payload else { continue }
            let message = try Self.message(kind: vector.kind, payload: payload)
            let encoded = try ClipboardStreamCodec.encode(message)
            #expect(Array(encoded.prefix(3)) == [0, 2, UInt8(vector.kind)])
            #expect(try ClipboardStreamCodec.decode(encoded) == message)
            if case let .announce(selection) = message {
                try selection.validate(limits: .default)
            }
            let body = try #require(JSONSerialization.jsonObject(with: encoded.dropFirst(3)) as? [String: Any])
            #expect(Set(body.keys) == Set(payload.keys))
            if let vectorFiles = payload["files"] as? [[String: Any]],
               let encodedFiles = body["files"] as? [[String: Any]] {
                for (vectorFile, encodedFile) in zip(vectorFiles, encodedFiles) {
                    #expect(Set(encodedFile.keys) == Set(vectorFile.keys))
                }
            }
        }
    }

    @Test func rangeVectorIsByteStableAcrossDecodeAndReencode() throws {
        let file = try GoldenVectorFile.load()
        let vector = try #require(file.vectors.first { $0.name == "range-with-data-byte-exact" })
        let frame = try #require(Data(hexEncoded: try #require(vector.frameHex)))
        guard case let .range(range) = try ClipboardStreamCodec.decode(frame) else {
            Issue.record("range vector did not decode to a range message")
            return
        }
        #expect(range.requestID == UUID(uuidString: "e0000005-1111-2222-3333-444455556666"))
        #expect(range.leaseID == UUID(uuidString: "e0000006-1111-2222-3333-444455556666"))
        #expect(range.fileID == UUID(uuidString: "e0000003-1111-2222-3333-444455556666"))
        #expect(range.offset == (UInt64(1) << 32) + 19)
        #expect(range.data == Data([0, 4, 5, 6, 254]))
        #expect(try ClipboardStreamCodec.encode(.range(range)) == frame)
    }

    @Test func selectionValidationAcceptsTheAnnounceAndRejectsPathEscapes() throws {
        let file = try GoldenVectorFile.load()
        let vector = try #require(file.vectors.first { $0.name == "announce-selection" })
        guard case let .announce(selection) = try Self.message(kind: vector.kind,
                                                               payload: try #require(vector.payload)) else {
            Issue.record("announce vector did not build an announce message")
            return
        }
        try selection.validate(limits: .default)
        let escape = ClipboardStreamSelection(epoch: selection.epoch, id: selection.id, generation: selection.generation,
            files: [.init(id: selection.files[0].id, name: "../escape", size: 1,
                          version: selection.files[0].version, contentType: selection.files[0].contentType)])
        #expect(throws: ClipboardStreamFailure.invalidRequest) { try escape.validate(limits: .default) }
    }

    private static func message(kind: Int, payload: [String: Any]) throws -> ClipboardStreamMessage {
        func uuid(_ key: String) throws -> UUID {
            guard let string = payload[key] as? String, let value = UUID(uuidString: string) else {
                throw ClipboardStreamFailure.invalidRequest
            }
            return value
        }
        func integer<T: FixedWidthInteger>(_ key: String) throws -> T {
            guard let number = payload[key] as? NSNumber, let value = T(exactly: number.uint64Value) else {
                throw ClipboardStreamFailure.invalidRequest
            }
            return value
        }
        func text(_ key: String) throws -> String {
            guard let value = payload[key] as? String else { throw ClipboardStreamFailure.invalidRequest }
            return value
        }
        func files(_ key: String) throws -> [ClipboardStreamFile] {
            guard let entries = payload[key] as? [[String: Any]] else { throw ClipboardStreamFailure.invalidRequest }
            var result: [ClipboardStreamFile] = []
            for entry in entries {
                func entryUUID(_ key: String) throws -> UUID {
                    guard let string = entry[key] as? String, let value = UUID(uuidString: string) else {
                        throw ClipboardStreamFailure.invalidRequest
                    }
                    return value
                }
                func entryInteger<T: FixedWidthInteger>(_ key: String) throws -> T {
                    guard let number = entry[key] as? NSNumber, let value = T(exactly: number.uint64Value) else {
                        throw ClipboardStreamFailure.invalidRequest
                    }
                    return value
                }
                func entryText(_ key: String, fallback: String) throws -> String {
                    guard let value = entry[key] as? String ?? (entry[key] == nil ? fallback : nil) else {
                        throw ClipboardStreamFailure.invalidRequest
                    }
                    return value
                }
                result.append(ClipboardStreamFile(id: try entryUUID("id"), name: try entryText("name", fallback: ""),
                    size: try entryInteger("size"), version: try entryText("version", fallback: ""),
                    contentType: try entryText("contentType", fallback: "public.data")))
            }
            return result
        }
        func digest(_ key: String) throws -> Data {
            guard let string = payload[key] as? String, let value = Data(base64Encoded: string) else {
                throw ClipboardStreamFailure.invalidRequest
            }
            return value
        }
        func failure(_ key: String) throws -> ClipboardStreamFailure {
            guard let string = payload[key] as? String, let value = ClipboardStreamFailure(rawValue: string) else {
                throw ClipboardStreamFailure.invalidRequest
            }
            return value
        }
        switch kind {
        case 1: return .announce(.init(epoch: try uuid("epoch"), id: try uuid("id"),
                                       generation: try integer("generation"), files: try files("files")))
        case 2: return .withdraw(.init(try uuid("id")))
        case 3: return .open(.init(requestID: try uuid("requestID"), selectionID: try uuid("selectionID"),
                                   fileID: try uuid("fileID"), version: try text("version")))
        case 4: return .opened(.init(requestID: try uuid("requestID"), selectionID: try uuid("selectionID"),
                                     fileID: try uuid("fileID"), leaseID: try uuid("leaseID"),
                                     size: try integer("size"), maximumReadBytes: try integer("maximumReadBytes")))
        case 5: return .read(.init(requestID: try uuid("requestID"), leaseID: try uuid("leaseID"),
                                   fileID: try uuid("fileID"), offset: try integer("offset"),
                                   length: try integer("length")))
        case 6: return .range(.init(requestID: try uuid("requestID"), leaseID: try uuid("leaseID"),
                                    fileID: try uuid("fileID"), offset: try integer("offset"), data: Data()))
        case 7: return .finish(.init(requestID: try uuid("requestID"), leaseID: try uuid("leaseID"), digest: try digest("digest")))
        case 8: return .finished(.init(requestID: try uuid("requestID"), leaseID: try uuid("leaseID"), digest: try digest("digest")))
        case 9: return .close(.init(try uuid("id")))
        case 10: return .error(.init(requestID: try uuid("requestID"), failure: try failure("failure")))
        default: throw ClipboardStreamFailure.invalidRequest
        }
    }
}

private struct GoldenVectorFile {
    let frameHeader: [Int]
    let kinds: [String: Int]
    let vectors: [Vector]
    struct Vector {
        let name: String
        let kind: Int
        let payload: [String: Any]?
        let frameHex: String?
    }
    static func load() throws -> GoldenVectorFile {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Docs/golden/clipboard-stream-v2-vectors.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let frameHeader = try #require(object["frameHeader"] as? [Int])
        let kinds = try #require(object["kinds"] as? [String: Int])
        var vectors: [Vector] = []
        for entry in try require(object["vectors"] as? [[String: Any]]) {
            vectors.append(Vector(name: try require(entry["name"] as? String), kind: try require(entry["kind"] as? Int),
                payload: entry["payloadJSON"] as? [String: Any], frameHex: entry["frameHex"] as? String))
        }
        return GoldenVectorFile(frameHeader: frameHeader, kinds: kinds, vectors: vectors)
    }
    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw ClipboardStreamFailure.invalidRequest }
        return value
    }
}

private extension Data {
    init?(hexEncoded string: String) {
        var bytes: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard next <= string.endIndex, let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
