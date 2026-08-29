import Foundation
import Security
import UniSpaceApplication
import UniSpaceDomain

public enum KeychainTrustStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

public struct WorkspaceKeyring: Equatable, Sendable {
    public let current: Data
    public let previous: [Data]

    public init(current: Data, previous: [Data] = []) {
        self.current = current
        self.previous = previous
    }

    public var candidates: [Data] {
        [current] + previous.filter { $0 != current }
    }
}

public final class KeychainTrustStore: TrustStore, @unchecked Sendable {
    private static let maximumPreviousKeyCount = 3

    private let service: String
    private let historyService: String
    private let lock = NSLock()

    public init(service: String = "com.layatai.unispace.workspace-key") {
        self.service = service
        historyService = "\(service).history"
    }

    public func workspaceKey(for workspaceID: WorkspaceID) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try readData(service: service, workspaceID: workspaceID)
    }

    public func workspaceKeyring(for workspaceID: WorkspaceID) throws -> WorkspaceKeyring? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = try readData(service: service, workspaceID: workspaceID) else {
            return nil
        }
        let previous = try readHistory(for: workspaceID)
        return WorkspaceKeyring(
            current: current,
            previous: Array(previous.filter { $0 != current }.prefix(Self.maximumPreviousKeyCount))
        )
    }

    public func storeWorkspaceKey(_ key: Data, for workspaceID: WorkspaceID) throws {
        lock.lock()
        defer { lock.unlock() }
        try removeData(service: historyService, workspaceID: workspaceID)
        try writeData(key, service: service, workspaceID: workspaceID)
    }

    public func rotateWorkspaceKey(_ key: Data, for workspaceID: WorkspaceID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let current = try readData(service: service, workspaceID: workspaceID) else {
            try writeData(key, service: service, workspaceID: workspaceID)
            return
        }
        guard current != key else { return }

        let storedHistory = try readHistory(for: workspaceID)
        let history = Array(
            ([current] + storedHistory)
                .filter { $0 != key }
                .reduce(into: [Data]()) { result, candidate in
                    if !result.contains(candidate) { result.append(candidate) }
                }
                .prefix(Self.maximumPreviousKeyCount)
        )
        try writeData(
            JSONEncoder().encode(history),
            service: historyService,
            workspaceID: workspaceID
        )
        try writeData(key, service: service, workspaceID: workspaceID)
    }

    public func removeWorkspaceKey(for workspaceID: WorkspaceID) throws {
        lock.lock()
        defer { lock.unlock() }
        try removeData(service: historyService, workspaceID: workspaceID)
        try removeData(service: service, workspaceID: workspaceID)
    }

    private func readData(service: String, workspaceID: WorkspaceID) throws -> Data? {
        var query = baseQuery(service: service, workspaceID: workspaceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainTrustStoreError.unexpectedStatus(status) }
        return result as? Data
    }

    private func readHistory(for workspaceID: WorkspaceID) throws -> [Data] {
        guard let data = try readData(service: historyService, workspaceID: workspaceID) else {
            return []
        }
        return try JSONDecoder().decode([Data].self, from: data)
    }

    private func writeData(_ data: Data, service: String, workspaceID: WorkspaceID) throws {
        let query = baseQuery(service: service, workspaceID: workspaceID)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainTrustStoreError.unexpectedStatus(updateStatus) }
            return
        }
        guard status == errSecItemNotFound else { throw KeychainTrustStoreError.unexpectedStatus(status) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainTrustStoreError.unexpectedStatus(addStatus) }
    }

    private func removeData(service: String, workspaceID: WorkspaceID) throws {
        let status = SecItemDelete(baseQuery(service: service, workspaceID: workspaceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTrustStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(service: String, workspaceID: WorkspaceID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: workspaceID.rawValue.uuidString
        ]
    }
}
