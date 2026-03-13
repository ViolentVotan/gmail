import GRDB

struct AttachmentRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "attachments"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    var id: String
    var messageId: String
    var gmailAttachmentId: String
    var filename: String?
    var mimeType: String?
    var fileType: String?
    var size: Int?
    var contentId: String?
    var direction: String?
    var indexingStatus: String?
    var extractedText: String?
    var indexedAt: Double?
    var retryCount: Int?
}
