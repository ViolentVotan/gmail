import Foundation
private import CryptoKit
private import Security

/// Persists OAuth tokens encrypted with AES-256-GCM.
/// Both the symmetric key and the encrypted token data are stored in the macOS Keychain.
@MainActor
final class TokenStore {
    static let shared = TokenStore()
    private init() {
        migrateKeyFromUserDefaultsIfNeeded()
        migrateTokensFromUserDefaultsIfNeeded()
    }

    private let defaults      = UserDefaults.standard
    private let keyPrefix     = "com.serif.token."
    private let accountsKey   = "com.serif.token.accounts"
    private let keychainService = "com.serif.token"
    private let keychainAccount = "encryption-key"
    private let legacyKeyUD    = "com.serif.token.key"

    // MARK: - Symmetric key (Keychain)

    private var symmetricKey: SymmetricKey {
        if let data = loadKeyFromKeychain() {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        saveKeyToKeychain(keyData)
        return key
    }

    private func loadKeyFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      keychainService,
            kSecAttrAccount as String:      keychainAccount,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func saveKeyToKeychain(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      keychainService,
            kSecAttrAccount as String:      keychainAccount,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let searchQuery: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
            ]
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(searchQuery as CFDictionary, update as CFDictionary)
        }
    }

    private func migrateKeyFromUserDefaultsIfNeeded() {
        guard let legacyData = defaults.data(forKey: legacyKeyUD) else { return }
        guard loadKeyFromKeychain() == nil else {
            defaults.removeObject(forKey: legacyKeyUD)
            return
        }
        saveKeyToKeychain(legacyData)
        defaults.removeObject(forKey: legacyKeyUD)
    }

    // MARK: - Token data (Keychain)

    private func tokenKeychainAccount(for accountID: String) -> String {
        "token-\(accountID)"
    }

    private func loadTokenData(for accountID: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      keychainService,
            kSecAttrAccount as String:      tokenKeychainAccount(for: accountID),
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func saveTokenData(_ data: Data, for accountID: String) {
        let account = tokenKeychainAccount(for: accountID)
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      keychainService,
            kSecAttrAccount as String:      account,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let searchQuery: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
            ]
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(searchQuery as CFDictionary, update as CFDictionary)
        }
    }

    private func deleteTokenData(for accountID: String) {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      keychainService,
            kSecAttrAccount as String:      tokenKeychainAccount(for: accountID),
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Migrates encrypted token data from UserDefaults to Keychain (one-time).
    private func migrateTokensFromUserDefaultsIfNeeded() {
        for accountID in allAccountIDs() {
            let udKey = keyPrefix + accountID
            guard let data = defaults.data(forKey: udKey) else { continue }
            // Only migrate if not already in Keychain
            if loadTokenData(for: accountID) == nil {
                saveTokenData(data, for: accountID)
            }
            defaults.removeObject(forKey: udKey)
        }
    }

    // MARK: - CRUD

    func save(_ token: AuthToken, for accountID: String) throws {
        let plaintext = try JSONEncoder().encode(token)
        let sealed    = try AES.GCM.seal(plaintext, using: symmetricKey)
        guard let combined = sealed.combined else { throw TokenStoreError.encryptionFailed }
        saveTokenData(combined, for: accountID)

        var ids = allAccountIDs()
        if !ids.contains(accountID) {
            ids.append(accountID)
            defaults.set(ids, forKey: accountsKey)
        }
    }

    func retrieve(for accountID: String) throws -> AuthToken? {
        // Read from Keychain; fall back to UserDefaults for unmigrated tokens
        let combined: Data
        if let keychainData = loadTokenData(for: accountID) {
            combined = keychainData
        } else if let udData = defaults.data(forKey: keyPrefix + accountID) {
            // Migrate on read
            saveTokenData(udData, for: accountID)
            defaults.removeObject(forKey: keyPrefix + accountID)
            combined = udData
        } else {
            return nil
        }
        let box       = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: symmetricKey)
        return try JSONDecoder().decode(AuthToken.self, from: plaintext)
    }

    func delete(for accountID: String) {
        deleteTokenData(for: accountID)
        defaults.removeObject(forKey: keyPrefix + accountID) // Clean up any legacy entry
        var ids = allAccountIDs()
        ids.removeAll { $0 == accountID }
        defaults.set(ids, forKey: accountsKey)
    }

    func allAccountIDs() -> [String] {
        defaults.stringArray(forKey: accountsKey) ?? []
    }
}

enum TokenStoreError: Error, LocalizedError {
    case encryptionFailed

    var errorDescription: String? { "Token encryption failed" }
}
