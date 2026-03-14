import GRDB

struct AccountSyncStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "account_sync_state"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    var id: Int = 1
    var contactsSyncToken: String?
    var otherContactsSyncToken: String?
    var lastHistoryId: String?
    var initialSyncComplete: Bool = false
    var initialSyncPageToken: String?
    var totalMessagesEstimate: Int?
    var syncedMessageCount: Int = 0
    var lastSyncAt: Double?
    var lastBodyPrefetchAt: Double?
    var directorySyncToken: String?
}
