import Foundation
import Synchronization

// MARK: - Stored Contact

struct StoredContact: Identifiable, Hashable, Sendable {
    var id: String { email }
    let name: String
    let email: String
    var photoURL: String?
}

// MARK: - Contact Store (Legacy cleanup — removes deprecated UserDefaults keys on account removal)

@MainActor
final class ContactStore {
    static let shared = ContactStore()
    private init() {}

    private enum LegacyKeys {
        static func contacts(_ id: String) -> String { "com.vikingz.vik.contacts.\(id)" }
        static func contactsSyncToken(_ id: String) -> String { "com.vikingz.vik.contacts.syncToken.\(id)" }
        static func contactsOtherSyncToken(_ id: String) -> String { "com.vikingz.vik.contacts.otherSyncToken.\(id)" }
    }

    /// Clean up legacy UserDefaults keys when an account is removed.
    func deleteAccount(_ accountID: String) {
        UserDefaults.standard.removeObject(forKey: LegacyKeys.contacts(accountID))
        UserDefaults.standard.removeObject(forKey: LegacyKeys.contactsSyncToken(accountID))
        UserDefaults.standard.removeObject(forKey: LegacyKeys.contactsOtherSyncToken(accountID))
    }
}

// MARK: - Contact Photo Cache

/// In-memory cache of email → Google profile photo URL, populated from People API at login.
/// Bounded to 500 entries with LRU eviction (matching BIMIService cache size).
final class ContactPhotoCache: Sendable {
    static let shared = ContactPhotoCache()
    private init() {}

    private let maxSize = 500

    /// Storage: [lowercased email: (url, lastAccess)] — LRU eviction by oldest access.
    private let storage = Mutex<[String: (url: String, lastAccess: Date)]>([:])

    func set(_ url: String, for email: String) {
        storage.withLock { dict in
            dict[email.lowercased()] = (url: url, lastAccess: Date())
            if dict.count > maxSize {
                let evictCount = maxSize / 4
                let sorted = dict.sorted { $0.value.lastAccess < $1.value.lastAccess }
                for entry in sorted.prefix(evictCount) {
                    dict.removeValue(forKey: entry.key)
                }
            }
        }
    }

    func get(_ email: String) -> String? {
        storage.withLock { dict in
            guard let entry = dict[email.lowercased()] else { return nil }
            dict[email.lowercased()] = (url: entry.url, lastAccess: Date())
            return entry.url
        }
    }

    func remove(_ email: String) {
        storage.withLock { _ = $0.removeValue(forKey: email.lowercased()) }
    }
}

// MARK: - Google User Info Model

struct GoogleUserInfo: Decodable, Sendable {
    let id:        String
    let email:     String
    let name:      String?
    let givenName: String?
    let picture:   String?

    enum CodingKeys: String, CodingKey {
        case id, email, name, picture
        case givenName = "given_name"
    }
}
