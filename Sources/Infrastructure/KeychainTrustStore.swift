import Foundation
import Security
import UniSpaceApplication
import UniSpaceDomain

public enum KeychainTrustStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

public final class KeychainTrustStore: TrustStore, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    public init(service: String = "com.layatai.unispace.workspace-key") {
        self.service = service
    }

    public func workspaceKey(for workspaceID: WorkspaceID) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery(workspaceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainTrustStoreError.unexpectedStatus(status) }
        return result as? Data
    }

    public func storeWorkspaceKey(_ key: Data, for workspaceID: WorkspaceID) throws {
        lock.lock()
        defer { lock.unlock() }
        let query = baseQuery(workspaceID)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update = [kSecValueData as String: key]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainTrustStoreError.unexpectedStatus(updateStatus) }
            return
        }
        guard status == errSecItemNotFound else { throw KeychainTrustStoreError.unexpectedStatus(status) }
        var add = query
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainTrustStoreError.unexpectedStatus(addStatus) }
    }

    public func removeWorkspaceKey(for workspaceID: WorkspaceID) throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(baseQuery(workspaceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTrustStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(_ workspaceID: WorkspaceID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: workspaceID.rawValue.uuidString
        ]
    }
}
