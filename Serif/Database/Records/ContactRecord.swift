import GRDB

struct ContactRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "contacts"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    var email: String
    var name: String?
    var photoUrl: String?
    var source: String?
    var resourceName: String?
    var updatedAt: Double?

    var id: String { email }
}
