import Foundation
import Security

/// Holds keys on this Mac: one data key per history folder (by the folder's store ID), and the
/// Secure Enclave key blob for hidden items.
protocol KeyStore: Sendable {
    func load(account: String) throws -> Data?
    func save(_ key: Data, account: String) throws
    func delete(account: String) throws
}

extension KeyStore {
    private static func account(_ storeID: UUID) -> String { "history-key." + storeID.uuidString }
    func load(storeID: UUID) throws -> Data? { try load(account: Self.account(storeID)) }
    func save(_ key: Data, storeID: UUID) throws { try save(key, account: Self.account(storeID)) }
    func delete(storeID: UUID) throws { try delete(account: Self.account(storeID)) }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? L("Unknown error")
        return String(localized: "Keychain error \(String(status)): \(message)")
    }
}

/// Stores keys as generic passwords in the login keychain.
///
/// The item is not synchronizable, so it never goes to iCloud Keychain. Its access list holds
/// only this app (by code signature), so other apps get a password prompt.
struct KeychainKeyStore: KeyStore {
    static let service = "com.iokoda.clipboard"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    func load(account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    func save(_ key: Data, account: String) throws {
        let base = query(account)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }

        var item = base
        item[kSecValueData as String] = key
        item[kSecAttrLabel as String] = "Clipboard history key"
        item[kSecAttrDescription as String] = "Clipboard encryption key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For tests and snapshot mode. Simulates a Keychain; `clear()` simulates a new Mac.
final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private var keys: [String: Data] = [:]
    private let lock = NSLock()

    func load(account: String) throws -> Data? { lock.withLock { keys[account] } }
    func save(_ key: Data, account: String) throws { lock.withLock { keys[account] = key } }
    func delete(account: String) throws { _ = lock.withLock { keys.removeValue(forKey: account) } }
    func clear() { lock.withLock { keys.removeAll() } }
}
