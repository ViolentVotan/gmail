import Foundation

struct AuthToken: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let tokenType: String
    let scope: String

    /// Returns true if the token is expired or expires within 60s.
    var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-60)
    }

    /// The set of granted scopes, split once from the space-delimited `scope` string.
    var grantedScopes: Set<String> {
        Set(scope.split(separator: " ").map(String.init))
    }

    /// Returns `true` when the token was granted the given scope URL.
    func hasScope(_ scopeURL: String) -> Bool {
        grantedScopes.contains(scopeURL)
    }

    init(accessToken: String, refreshToken: String?, expiresIn: Int, tokenType: String, scope: String) {
        self.accessToken  = accessToken
        self.refreshToken = refreshToken
        self.expiresAt    = Date().addingTimeInterval(TimeInterval(expiresIn))
        self.tokenType    = tokenType
        self.scope        = scope
    }
}
