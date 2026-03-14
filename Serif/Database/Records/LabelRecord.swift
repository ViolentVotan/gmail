import GRDB

struct LabelRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "labels"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    var gmailId: String
    var name: String
    var type: String?
    var bgColor: String?
    var textColor: String?

    var id: String { gmailId }

    init(gmailId: String, name: String, type: String?, bgColor: String?, textColor: String?) {
        self.gmailId = gmailId
        self.name = name
        self.type = type
        self.bgColor = bgColor
        self.textColor = textColor
    }

    init(from gmail: GmailLabel) {
        self.gmailId = gmail.id
        self.name = gmail.name
        self.type = gmail.type
        self.bgColor = gmail.color?.backgroundColor
        self.textColor = gmail.color?.textColor
    }
}

// MARK: - GRDB Associations

extension LabelRecord {
    static let messageLabels = hasMany(MessageLabelRecord.self, using: ForeignKey(["label_id"]))
}
