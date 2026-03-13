import GRDB

struct MessageLabelRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "message_labels"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    var messageId: String
    var labelId: String
}

// MARK: - GRDB Associations

extension MessageLabelRecord {
    static let message = belongsTo(MessageRecord.self, using: ForeignKey(["message_id"]))
    static let label = belongsTo(LabelRecord.self, using: ForeignKey(["label_id"]))
}
