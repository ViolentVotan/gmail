internal import GRDB

struct EmailTagRecord: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "email_tags"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    var messageId: String
    var needsReply: Bool
    var fyiOnly: Bool
    var hasDeadline: Bool
    var financial: Bool

    var id: String { messageId }
}
