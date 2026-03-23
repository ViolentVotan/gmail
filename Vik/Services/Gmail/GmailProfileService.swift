import Foundation

@MainActor
final class GmailProfileService {
    static let shared = GmailProfileService()
    private let client = GmailAPIClient.shared
    nonisolated private static let encoder = JSONEncoder()
    private init() {}

    // MARK: - Gmail Profile

    @concurrent func getProfile(accountID: String) async throws(GmailAPIError) -> GmailProfile {
        try await client.request(
            path: "/users/me/profile",
            fields: "emailAddress,historyId,messagesTotal,threadsTotal",
            accountID: accountID
        )
    }

    // MARK: - Google User Info (name, avatar)

    /// Fetches display name and profile picture from Google's userinfo endpoint.
    /// Takes an access token directly because this is called during initial sign-in
    /// before the account ID (email) is known.
    @concurrent func getUserInfo(accessToken: String) async throws(GmailAPIError) -> GoogleUserInfo {
        try await GmailAPIClient.requestWithToken(
            url: "https://www.googleapis.com/oauth2/v2/userinfo",
            token: accessToken
        )
    }

    // MARK: - SendAs / Aliases

    /// Returns all SendAs aliases for the account.
    @concurrent func listSendAs(accountID: String) async throws(GmailAPIError) -> [GmailSendAs] {
        let response: GmailSendAsListResponse = try await client.request(
            path: "/users/me/settings/sendAs",
            fields: "sendAs(sendAsEmail,displayName,signature,isDefault,isPrimary)",
            accountID: accountID
        )
        return response.sendAs ?? []
    }

    /// Updates the signature HTML for a specific send-as alias.
    @discardableResult
    @concurrent func updateSignature(sendAsEmail: String, signature: String, accountID: String) async throws(GmailAPIError) -> GmailSendAs {
        struct UpdateRequest: Encodable { let signature: String }
        let body: Data
        do {
            body = try Self.encoder.encode(UpdateRequest(signature: signature))
        } catch {
            throw .encodingError(error)
        }
        return try await client.request(
            path: GmailPathBuilder.sendAsPath(sendAsEmail),
            method: "PATCH", body: body, contentType: "application/json",
            fields: "sendAsEmail,displayName,signature",
            accountID: accountID
        )
    }

    /// Returns the signature HTML for the default send-as address.
    @concurrent func getSignature(accountID: String) async throws(GmailAPIError) -> String? {
        let aliases = try await listSendAs(accountID: accountID)
        return aliases.first(where: { $0.isDefault == true })?.signature
    }

}
