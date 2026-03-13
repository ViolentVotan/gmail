import GRDB

struct FolderSyncStateRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "folder_sync_state"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    var folderKey: String
    var historyId: String?
    var nextPageToken: String?
    var lastFullSync: Double?
    var lastDeltaSync: Double?

    var id: String { folderKey }
}
