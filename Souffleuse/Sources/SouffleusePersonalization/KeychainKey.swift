import CryptoKit
import Foundation
import Security

/// Minimal wrapper for storing / loading the 256-bit AES-GCM key used by
/// `TypingHistoryStore`. Backed by `kSecClassGenericPassword`. The key is
/// generated on first access and persisted to the login keychain so it
/// survives restarts but follows the user's macOS account.
public enum KeychainKey {
    public static let service: String = "dev.cocotypist.Souffleuse.history"
    public static let account: String = "TypingHistoryStore.aesgcm"

    public enum KeychainError: Error, Equatable {
        case osStatus(OSStatus)
        case invalidKeyData
    }

    /// Reads the key or creates a fresh random one. The created key is stored
    /// in the keychain before returning so callers always operate against
    /// persisted material.
    public static func loadOrCreate() throws -> SymmetricKey {
        if let existing = try load() { return existing }
        let key = SymmetricKey(size: .bits256)
        try store(key)
        return key
    }

    /// Reads the stored key, returning nil if no entry exists.
    public static func load() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &item) { ptr in
            SecItemCopyMatching(query as CFDictionary, ptr)
        }
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else {
                throw KeychainError.invalidKeyData
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Persists `key` (overwriting any existing entry).
    public static func store(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let delStatus = SecItemDelete(baseQuery as CFDictionary)
        if delStatus != errSecSuccess && delStatus != errSecItemNotFound {
            throw KeychainError.osStatus(delStatus)
        }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.osStatus(addStatus)
        }
    }

    /// Removes the stored key. No-op if absent.
    @discardableResult
    public static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
