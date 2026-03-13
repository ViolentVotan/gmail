import GRDB

struct EmailTagRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "email_tags"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    var messageId: String
    var needsReply: Bool
    var fyiOnly: Bool
    var hasDeadline: Bool
    var financial: Bool
    var classifiedAt: Double?
    var classifierVersion: Int?

    var id: String { messageId }
}
