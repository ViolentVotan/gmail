import Foundation
import GRDB

// MARK: - Stored Contact

struct StoredContact: Codable, Identifiable, Hashable, Sendable {
    var id: String { email }
    let name: String
    let email: String
    var photoURL: String?
}

// MARK: - Contact Store (GRDB-backed, reads from per-account SQLite)

@MainActor
final class ContactStore {
    static let shared = ContactStore()
    private init() {}

    func contacts(for accountID: String) -> [StoredContact] {
        (try? MailDatabase.shared(for: accountID).dbPool.read { db in
            try MailDatabaseQueries.allContacts(in: db).map {
                StoredContact(name: $0.name ?? $0.email, email: $0.email, photoURL: $0.photoUrl)
            }
        }) ?? []
    }

    func contactCount(for accountID: String) -> Int {
        (try? MailDatabase.shared(for: accountID).dbPool.read { db in
            try MailDatabaseQueries.contactCount(in: db)
        }) ?? 0
    }

    /// Clean up legacy UserDefaults keys when an account is removed.
    func deleteAccount(_ accountID: String) {
        UserDefaults.standard.removeObject(forKey: "com.serif.contacts.\(accountID)")
        UserDefaults.standard.removeObject(forKey: "com.serif.contacts.syncToken.\(accountID)")
        UserDefaults.standard.removeObject(forKey: "com.serif.contacts.otherSyncToken.\(accountID)")
    }
}

// MARK: - Contact Photo Cache

/// In-memory cache of email → Google profile photo URL, populated from People API at login.
/// NSLock is safe here: all critical sections are synchronous (no suspension points inside lock).
final class ContactPhotoCache: @unchecked Sendable {
    static let shared = ContactPhotoCache()
    private init() {}

    private let lock = NSLock()
    private var cache: [String: String] = [:]

    func set(_ url: String, for email: String) {
        lock.withLock { cache[email.lowercased()] = url }
    }

    func get(_ email: String) -> String? {
        lock.withLock { cache[email.lowercased()] }
    }

    func remove(_ email: String) {
        lock.withLock { _ = cache.removeValue(forKey: email.lowercased()) }
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
