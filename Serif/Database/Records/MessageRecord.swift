import Foundation
import GRDB

struct MessageRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    // Primary key
    var gmailId: String

    // Core fields
    var threadId: String
    var historyId: String?
    var internalDate: Double
    var snippet: String?
    var sizeEstimate: Int?
    var subject: String?
    var senderEmail: String?
    var senderName: String?
    var toRecipients: String?   // JSON array
    var ccRecipients: String?   // JSON array
    var bccRecipients: String?  // JSON array
    var replyTo: String?
    var messageIdHeader: String?
    var inReplyTo: String?
    var bodyHtml: String?
    var bodyPlain: String?
    var rawHeaders: String?     // JSON array
    var hasAttachments: Bool
    var isRead: Bool
    var isStarred: Bool
    var isFromMailingList: Bool
    var unsubscribeUrl: String?
    var fullBodyFetched: Bool
    var threadMessageCount: Int
    var fetchedAt: Double?

    var id: String { gmailId }

    // MARK: - Conversion from Gmail API model

    init(from gmail: GmailMessage) {
        self.gmailId = gmail.id
        self.threadId = gmail.threadId
        self.historyId = gmail.historyId
        self.internalDate = gmail.date?.timeIntervalSince1970 ?? 0
        self.snippet = gmail.snippet
        self.sizeEstimate = gmail.sizeEstimate
        self.subject = gmail.subject
        let fromHeader = gmail.from
        // Parse "Name <email>" format
        if let open = fromHeader.lastIndex(of: "<"), let close = fromHeader.lastIndex(of: ">") {
            self.senderEmail = String(fromHeader[fromHeader.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            self.senderName = String(fromHeader[fromHeader.startIndex..<open])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        } else {
            self.senderEmail = fromHeader.trimmingCharacters(in: .whitespaces)
            self.senderName = nil
        }
        self.toRecipients = Self.encodeRecipients(gmail.to)
        self.ccRecipients = Self.encodeRecipients(gmail.cc)
        self.bccRecipients = nil // BCC only available for sent messages via raw format
        self.replyTo = gmail.replyTo
        self.messageIdHeader = gmail.messageID
        self.inReplyTo = gmail.inReplyTo
        self.bodyHtml = gmail.htmlBody
        self.bodyPlain = gmail.plainBody
        self.rawHeaders = Self.encodeHeaders(gmail.payload?.headers)
        self.hasAttachments = gmail.attachmentParts.count > 0
        self.isRead = !(gmail.labelIds?.contains("UNREAD") ?? false)
        self.isStarred = gmail.labelIds?.contains("STARRED") ?? false
        self.isFromMailingList = gmail.isFromMailingList
        self.unsubscribeUrl = gmail.unsubscribeURL?.absoluteString
        self.fullBodyFetched = gmail.htmlBody != nil || gmail.plainBody != nil
        self.threadMessageCount = 1
        self.fetchedAt = Date().timeIntervalSince1970
    }

    // MARK: - Test fixture

    static func fixture(
        gmailId: String = "msg-\(UUID().uuidString.prefix(8))",
        threadId: String = "thread-1",
        subject: String = "Test Subject",
        senderEmail: String = "test@example.com",
        internalDate: Double = Date().timeIntervalSince1970
    ) -> MessageRecord {
        var r = MessageRecord(from: GmailMessage.testFixture(
            id: gmailId,
            threadId: threadId,
            subject: subject,
            from: senderEmail
        ))
        r.internalDate = internalDate
        r.subject = subject
        r.senderEmail = senderEmail
        r.senderName = "Test User"
        r.snippet = "Test snippet"
        r.sizeEstimate = 1024
        r.fetchedAt = nil
        return r
    }

    // MARK: - Private helpers

    private static func encodeRecipients(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let addresses = raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return try? String(data: JSONEncoder().encode(addresses), encoding: .utf8)
    }

    private static func encodeHeaders(_ headers: [GmailHeader]?) -> String? {
        guard let headers else { return nil }
        return try? String(data: JSONEncoder().encode(headers), encoding: .utf8)
    }
}

// MARK: - GRDB Associations

extension MessageRecord {
    static let messageLabels = hasMany(MessageLabelRecord.self, using: ForeignKey(["message_id"]))
    static let labels = hasMany(LabelRecord.self, through: messageLabels, using: MessageLabelRecord.label)
    static let attachments = hasMany(AttachmentRecord.self, using: ForeignKey(["message_id"]))
    static let tags = hasOne(EmailTagRecord.self, using: ForeignKey(["message_id"]))
}
