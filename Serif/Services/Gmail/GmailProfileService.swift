import Foundation

@MainActor
final class GmailProfileService {
    static let shared = GmailProfileService()
    private let client = GmailAPIClient.shared
    private init() {}

    // MARK: - Gmail Profile

    @concurrent func getProfile(accountID: String) async throws(GmailAPIError) -> GmailProfile {
        try await client.request(
            path: "/users/me/profile",
            accountID: accountID
        )
    }

    // MARK: - Google User Info (name, avatar)

    /// Fetches display name and profile picture from Google's userinfo endpoint.
    /// Takes an access token directly because this is called during initial sign-in
    /// before the account ID (email) is known.
    @concurrent func getUserInfo(accessToken: String) async throws(GmailAPIError) -> GoogleUserInfo {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else {
            throw .invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Serif/1.0 (gzip)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw .networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidURL }
        guard (200...299).contains(http.statusCode) else {
            throw .httpError(http.statusCode, data)
        }
        do {
            return try JSONDecoder().decode(GoogleUserInfo.self, from: data)
        } catch {
            throw .decodingError(error)
        }
    }

    // MARK: - SendAs / Aliases

    /// Returns all SendAs aliases for the account.
    @concurrent func listSendAs(accountID: String) async throws(GmailAPIError) -> [GmailSendAs] {
        let response: GmailSendAsListResponse = try await client.request(
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
        return try await client.request(
            path: GmailPathBuilder.sendAsPath(sendAsEmail),
            method: "PATCH", body: body, contentType: "application/json",
            accountID: accountID
        )
    }

    /// Returns the signature HTML for the default send-as address.
    @concurrent func getSignature(accountID: String) async throws(GmailAPIError) -> String? {
        let aliases = try await listSendAs(accountID: accountID)
        return aliases.first(where: { $0.isDefault == true })?.signature
    }

}
