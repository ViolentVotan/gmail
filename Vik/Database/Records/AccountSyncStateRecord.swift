internal import GRDB

struct AccountSyncStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "account_sync_state"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    private(set) var id: Int = 1
    var contactsSyncToken: String?
    var contactsSyncTokenAt: Double?
    var otherContactsSyncToken: String?
    var otherContactsSyncTokenAt: Double?
    var lastHistoryId: String?
    var initialSyncComplete: Bool = false
    var initialSyncPageToken: String?
    var totalMessagesEstimate: Int?
    var syncedMessageCount: Int = 0
    var lastSyncAt: Double?
    var directorySyncToken: String?
    var labelsEtag: String?
    var lastBodyPrefetchAt: Double?
}
