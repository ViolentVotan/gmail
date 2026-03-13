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

// MARK: - UI Model Conversion

extension MessageRecord {
    /// Convert to UI Email model for display in list views.
    func toEmail(labels: [LabelRecord], tags: EmailTagRecord?) -> Email {
        let sender = Contact(
            name: senderName ?? senderEmail ?? "Unknown",
            email: senderEmail ?? ""
        )
        let userLabels = labels.filter { $0.type == "user" }.map { label in
            EmailLabel(
                id: UUID(),
                name: label.name,
                color: label.bgColor ?? "#e8eaed",
                textColor: label.textColor ?? "#3c4043"
            )
        }
        // Parse recipients from JSON
        let toList = Self.decodeRecipientStrings(toRecipients)
        let ccList = Self.decodeRecipientStrings(ccRecipients)

        // Derive folder from system label IDs in the labels array
        let systemLabelIds = Set(labels.compactMap { $0.type == "system" ? $0.gmailId : nil })
        let folder: Folder
        if systemLabelIds.contains("SENT") {
            folder = .sent
        } else if systemLabelIds.contains("DRAFT") {
            folder = .drafts
        } else if systemLabelIds.contains("SPAM") {
            folder = .spam
        } else if systemLabelIds.contains("TRASH") {
            folder = .trash
        } else if systemLabelIds.contains("STARRED") {
            folder = .starred
        } else {
            folder = .inbox
        }

        let isDraft = systemLabelIds.contains("DRAFT")
        let gmailLabelIDs = labels.map { $0.gmailId }

        return Email(
            sender: sender,
            recipients: toList.map { Contact(name: $0, email: $0) },
            cc: ccList.map { Contact(name: $0, email: $0) },
            subject: subject ?? "(No Subject)",
            body: bodyHtml ?? bodyPlain ?? "",
            preview: snippet ?? "",
            date: Date(timeIntervalSince1970: internalDate),
            isRead: isRead,
            isStarred: isStarred,
            hasAttachments: hasAttachments,
            attachments: [],
            folder: folder,
            labels: userLabels,
            isDraft: isDraft,
            isGmailDraft: isDraft,
            gmailMessageID: gmailId,
            gmailThreadID: threadId,
            gmailLabelIDs: gmailLabelIDs,
            threadMessageCount: threadMessageCount,
            isFromMailingList: isFromMailingList,
            unsubscribeURL: unsubscribeUrl.flatMap { URL(string: $0) }
        )
    }

    private static func decodeRecipientStrings(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

// MARK: - Reverse conversion to GmailMessage

extension MessageRecord {
    func toGmailMessage() -> GmailMessage {
        var labelIds: [String] = []
        if !isRead { labelIds.append("UNREAD") }
        if isStarred { labelIds.append("STARRED") }

        return GmailMessage(
            id: gmailId,
            threadId: threadId,
            labelIds: labelIds,
            snippet: snippet,
            internalDate: String(Int64(internalDate * 1000)), // Convert seconds to milliseconds string
            payload: GmailMessagePart(
                partId: nil,
                mimeType: bodyHtml != nil ? "text/html" : "text/plain",
                filename: nil,
                headers: buildHeaders(),
                body: buildBody(),
                parts: nil
            ),
            sizeEstimate: sizeEstimate,
            historyId: historyId,
            raw: nil
        )
    }

    private func buildHeaders() -> [GmailHeader] {
        var headers: [GmailHeader] = []
        if let subject { headers.append(GmailHeader(name: "Subject", value: subject)) }
        if let senderName, let senderEmail {
            headers.append(GmailHeader(name: "From", value: "\(senderName) <\(senderEmail)>"))
        } else if let senderEmail {
            headers.append(GmailHeader(name: "From", value: senderEmail))
        }
        if let toRecipients { headers.append(GmailHeader(name: "To", value: decodeRecipientsAsString(toRecipients))) }
        if let ccRecipients { headers.append(GmailHeader(name: "Cc", value: decodeRecipientsAsString(ccRecipients))) }
        if let replyTo { headers.append(GmailHeader(name: "Reply-To", value: replyTo)) }
        if let messageIdHeader { headers.append(GmailHeader(name: "Message-ID", value: messageIdHeader)) }
        if let inReplyTo { headers.append(GmailHeader(name: "In-Reply-To", value: inReplyTo)) }
        if let url = unsubscribeUrl { headers.append(GmailHeader(name: "List-Unsubscribe", value: url)) }
        return headers
    }

    private func buildBody() -> GmailMessageBody? {
        let bodyContent = bodyHtml ?? bodyPlain
        guard let bodyContent else { return nil }
        // Re-encode as base64url so GmailMessage.htmlBody / plainBody can decode it
        let base64url = Data(bodyContent.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return GmailMessageBody(attachmentId: nil, size: bodyContent.utf8.count, data: base64url)
    }

    private func decodeRecipientsAsString(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return json }
        return arr.joined(separator: ", ")
    }
}

// MARK: - GRDB Associations

extension MessageRecord {
    static let messageLabels = hasMany(MessageLabelRecord.self, using: ForeignKey(["message_id"]))
    static let labels = hasMany(LabelRecord.self, through: messageLabels, using: MessageLabelRecord.label)
    static let attachments = hasMany(AttachmentRecord.self, using: ForeignKey(["message_id"]))
    static let tags = hasOne(EmailTagRecord.self, using: ForeignKey(["message_id"]))
}
