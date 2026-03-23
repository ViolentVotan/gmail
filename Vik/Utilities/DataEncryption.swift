import Foundation
private import CryptoKit
private import os
private import Security
import Synchronization

/// Shared AES-256-GCM encryption utility.
///
/// Manages one symmetric key per Keychain `service`/`account` pair.
/// The key is generated on first use and cached in memory for subsequent calls.
enum DataEncryption {

    // MARK: - Error

    enum EncryptionError: Error {
        case encryptionFailed
        case decryptionFailed
    }

    // MARK: - Key cache

    /// Per-slot key cache keyed by "\(service):\(account)".
    private nonisolated static let keyCache = Mutex<[String: SymmetricKey]>([:])

    // MARK: - Public API

    /// Returns (and caches) the AES-256 symmetric key for the given Keychain slot,
    /// generating and storing a new one if none exists yet.
    private nonisolated static func symmetricKey(service: String, account: String) -> SymmetricKey {
        let cacheKey = "\(service):\(account)"
        return keyCache.withLock { cache in
            if let existing = cache[cacheKey] { return existing }
            let key: SymmetricKey
            if let data = loadKeyFromKeychain(service: service, account: account) {
                key = SymmetricKey(data: data)
            } else {
                key = SymmetricKey(size: .bits256)
                saveKeychainItem(
                    service: service,
                    account: account,
                    data: key.withUnsafeBytes { Data($0) }
                )
            }
            cache[cacheKey] = key
            return key
        }
    }

    /// Encrypts `plaintext` with AES-256-GCM using the key for the given Keychain slot.
    nonisolated static func encrypt(
        _ plaintext: Data,
        service: String,
        account: String
    ) throws -> Data {
        let key = symmetricKey(service: service, account: account)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw EncryptionError.encryptionFailed }
        return combined
    }

    /// Decrypts AES-256-GCM `ciphertext` using the key for the given Keychain slot.
    nonisolated static func decrypt(
        _ ciphertext: Data,
        service: String,
        account: String
    ) throws -> Data {
        let key = symmetricKey(service: service, account: account)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        guard let plaintext = try? AES.GCM.open(box, using: key) else {
            throw EncryptionError.decryptionFailed
        }
        return plaintext
    }

    // MARK: - Keychain helpers

    /// Loads raw key bytes from the Keychain. Returns `nil` if not found.
    nonisolated static func loadKeyFromKeychain(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private nonisolated static let logger = Logger(category: "DataEncryption")

    /// Saves (or updates) a Keychain item with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
    nonisolated static func saveKeychainItem(service: String, account: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let search: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let updateStatus = SecItemUpdate(
                search as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus != errSecSuccess {
                logger.error("Keychain update failed (service=\(service), account=\(account)): OSStatus \(updateStatus)")
            }
        } else if status != errSecSuccess {
            logger.error("Keychain add failed (service=\(service), account=\(account)): OSStatus \(status)")
        }
    }
}
