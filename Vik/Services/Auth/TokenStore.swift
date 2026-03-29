import Foundation
private import os
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

    private nonisolated let logger = Logger(category: "TokenStore")
    private let defaults      = UserDefaults.standard
    private let keyPrefix     = "com.vikingz.vik.token."
    private let accountsKey   = "com.vikingz.vik.token.accounts"
    private let keychainService: String = {
        #if DEBUG
        "com.vikingz.vik.token.debug"
        #else
        "com.vikingz.vik.token"
        #endif
    }()
    private let keychainAccount = "encryption-key"
    private let legacyKeyUD    = "com.vikingz.vik.token.key"

    // MARK: - Symmetric key migration (Keychain)

    private func migrateKeyFromUserDefaultsIfNeeded() {
        guard let legacyData = defaults.data(forKey: legacyKeyUD) else { return }
        guard DataEncryption.loadKeyFromKeychain(
            service: keychainService, account: keychainAccount
        ) == nil else {
            defaults.removeObject(forKey: legacyKeyUD)
            return
        }
        DataEncryption.saveKeychainItem(
            service: keychainService, account: keychainAccount, data: legacyData
        )
        defaults.removeObject(forKey: legacyKeyUD)
    }

    // MARK: - Token data (Keychain)

    nonisolated private func tokenKeychainAccount(for accountID: String) -> String {
        "token-\(accountID)"
    }

    nonisolated private func loadTokenData(for accountID: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:                        kSecClassGenericPassword,
            kSecAttrService as String:                  keychainService,
            kSecAttrAccount as String:                  tokenKeychainAccount(for: accountID),
            kSecReturnData as String:                   true,
            kSecMatchLimit as String:                   kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String:     true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger.error("Keychain read failed (account=\(accountID)): OSStatus \(status)")
            }
            return nil
        }
        return result as? Data
    }

    nonisolated private func saveTokenData(_ data: Data, for accountID: String) {
        DataEncryption.saveKeychainItem(
            service: keychainService,
            account: tokenKeychainAccount(for: accountID),
            data: data
        )
    }

    nonisolated private func deleteTokenData(for accountID: String) {
        let query: [String: Any] = [
            kSecClass as String:                        kSecClassGenericPassword,
            kSecAttrService as String:                  keychainService,
            kSecAttrAccount as String:                  tokenKeychainAccount(for: accountID),
            kSecUseDataProtectionKeychain as String:     true,
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

    @concurrent func save(_ token: AuthToken, for accountID: String) async throws {
        let plaintext = try JSONEncoder().encode(token)
        let combined  = try DataEncryption.encrypt(
            plaintext, service: keychainService, account: keychainAccount
        )
        saveTokenData(combined, for: accountID)

        await MainActor.run {
            var ids = allAccountIDs()
            if !ids.contains(accountID) {
                ids.append(accountID)
                defaults.set(ids, forKey: accountsKey)
            }
        }
    }

    @concurrent func retrieve(for accountID: String) async throws -> AuthToken? {
        // Primary path: read from Keychain (nonisolated — no MainActor hop)
        let combined: Data
        if let keychainData = loadTokenData(for: accountID) {
            combined = keychainData
        } else {
            // Legacy fallback: check UserDefaults for unmigrated tokens (requires MainActor)
            let udKey = keyPrefix + accountID
            guard let udData = await MainActor.run(body: { defaults.data(forKey: udKey) }) else {
                return nil
            }
            // Migrate to Keychain and clean up UserDefaults
            saveTokenData(udData, for: accountID)
            await MainActor.run { defaults.removeObject(forKey: udKey) }
            combined = udData
        }
        let plaintext = try DataEncryption.decrypt(
            combined, service: keychainService, account: keychainAccount
        )
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
