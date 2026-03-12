import Foundation

// MARK: - Stored Contact

struct StoredContact: Codable, Identifiable, Hashable, Sendable {
    var id: String { email }
    let name: String
    let email: String
    var photoURL: String?
}

// MARK: - Contact Store (UserDefaults persistence)

@MainActor
final class ContactStore {
    static let shared = ContactStore()
    private init() {}

    func contacts(for accountID: String) -> [StoredContact] {
        let key = "com.serif.contacts.\(accountID)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([StoredContact].self, from: data)
        else { return [] }
        return decoded
    }

    func setContacts(_ contacts: [StoredContact], for accountID: String) {
        let key = "com.serif.contacts.\(accountID)"
        if let data = try? JSONEncoder().encode(contacts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func syncToken(for accountID: String) -> String? {
        UserDefaults.standard.string(forKey: "com.serif.contacts.syncToken.\(accountID)")
    }

    func setSyncToken(_ token: String?, for accountID: String) {
        UserDefaults.standard.set(token, forKey: "com.serif.contacts.syncToken.\(accountID)")
    }

    func deleteAccount(_ accountID: String) {
        UserDefaults.standard.removeObject(forKey: "com.serif.contacts.\(accountID)")
        UserDefaults.standard.removeObject(forKey: "com.serif.contacts.syncToken.\(accountID)")
    }
}

// MARK: - Contact Photo Cache

/// In-memory cache of email → Google profile photo URL, populated from People API at login.
/// Thread-safe via NSLock – deliberately `@unchecked Sendable` so callers on any isolation
/// domain can read/write without awaiting.
final class ContactPhotoCache: @unchecked Sendable {
    static let shared = ContactPhotoCache()
    private init() {}

    private var cache: [String: String] = [:]
    private let lock = NSLock()

    func set(_ url: String, for email: String) {
        lock.withLock { cache[email.lowercased()] = url }
    }

    func get(_ email: String) -> String? {
        lock.withLock { cache[email.lowercased()] }
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
