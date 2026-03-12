import Foundation

@MainActor
final class GmailProfileService {
    static let shared = GmailProfileService()
    private init() {}

    // MARK: - Gmail Profile

    @concurrent func getProfile(accountID: String) async throws(GmailAPIError) -> GmailProfile {
        try await GmailAPIClient.shared.request(
            path: "/users/me/profile",
            accountID: accountID
        )
    }

    // MARK: - Google User Info (name, avatar)

    /// Fetches display name and profile picture from Google's userinfo endpoint.
    @concurrent func getUserInfo(accessToken: String) async throws -> GoogleUserInfo {
        let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(GoogleUserInfo.self, from: data)
    }

    // MARK: - SendAs / Aliases

    /// Returns all SendAs aliases for the account.
    @concurrent func listSendAs(accountID: String) async throws(GmailAPIError) -> [GmailSendAs] {
        let response: GmailSendAsListResponse = try await GmailAPIClient.shared.request(
            path: "/users/me/settings/sendAs",
            fields: "sendAs(sendAsEmail,displayName,signature,isDefault,isPrimary)",
            accountID: accountID
        )
        return response.sendAs
    }

    /// Updates the signature HTML for a specific send-as alias.
    @discardableResult
    @concurrent func updateSignature(sendAsEmail: String, signature: String, accountID: String) async throws(GmailAPIError) -> GmailSendAs {
        struct UpdateRequest: Encodable { let signature: String }
        let body: Data
        do {
            body = try JSONEncoder().encode(UpdateRequest(signature: signature))
        } catch {
            throw .encodingError(error)
        }
        return try await GmailAPIClient.shared.request(
            path: GmailPathBuilder.sendAsPath(sendAsEmail),
            method: "PUT", body: body, contentType: "application/json",
            accountID: accountID
        )
    }

    /// Returns the signature HTML for the default send-as address.
    @concurrent func getSignature(accountID: String) async throws(GmailAPIError) -> String? {
        let aliases = try await listSendAs(accountID: accountID)
        return aliases.first(where: { $0.isDefault == true })?.signature
    }

}

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
        let data = try? JSONEncoder().encode(contacts)
        UserDefaults.standard.set(data, forKey: key)
    }

    func deleteAccount(_ accountID: String) {
        UserDefaults.standard.removeObject(forKey: "com.serif.contacts.\(accountID)")
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
