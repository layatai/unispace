import Foundation
import UniSpaceDomain

extension KeyedDecodingContainer {
    func decodeUUIDIdentifier<Value: UUIDIdentifier>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> Value {
        Value(rawValue: try decode(UUID.self, forKey: key))
    }
}

extension KeyedEncodingContainer {
    mutating func encodeUUIDIdentifier<Value: UUIDIdentifier>(
        _ value: Value,
        forKey key: Key
    ) throws {
        try encode(value.rawValue, forKey: key)
    }
}
