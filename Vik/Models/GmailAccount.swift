import Foundation

/// Represents a connected Gmail account.
struct GmailAccount: Identifiable, Codable, Equatable, Sendable {
    /// `id` is intentionally computed (not stored) — it is NOT included in Codable encoding.
    /// The `email` property serves as the stable identity for this type.
    /// If persistence needs an `id` key, add a CodingKeys enum mapping `email` to `"id"`.
    var id: String { email }
    let email:             String
    let displayName:       String
    let profilePictureURL: URL?
    var accentColor:       String?
}
