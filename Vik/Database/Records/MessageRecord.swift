import Foundation
internal import GRDB

struct MessageRecord: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
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
    var referencesHeader: String?
    var bodyHtml: String?
    var bodyPlain: String?
    var rawHeaders: String?     // JSON array
    var hasAttachments: Bool
    var isRead: Bool
    var isStarred: Bool
    var isFromMailingList: Bool
    var unsubscribeUrl: String?
    var fullBodyFetched: Bool
    var bodyFetchAttempts: Int
    var threadMessageCount: Int
    var fetchedAt: Double?

    /// Gmail draft ID (e.g. "r1234") — only populated for messages with the DRAFT label.
    /// Distinct from `gmailId` which is the message ID. The Gmail `drafts/send` endpoint
    /// requires this draft ID, not the message ID.
    var gmailDraftId: String?
    var attachmentCount: Int

    var id: String { gmailId }

    // MARK: - Conversion from Gmail API model

    init(from gmail: GmailMessage) {
        // Build header map once — O(headers) — instead of O(headers) per header lookup.
        // This init reads 7+ headers; the map avoids repeated linear scans with lowercased().
        let headers = gmail.headerMap

        // Single-pass MIME traversal — extracts body (HTML + plain) and attachment presence
        // in one walk instead of 3–5 separate recursive traversals.
        let mime = Self.extractMIMEInfo(from: gmail.payload)

        self.gmailId = gmail.id
        self.threadId = gmail.threadId
        self.historyId = gmail.historyId
        self.internalDate = gmail.date?.timeIntervalSince1970 ?? 0
        self.snippet = gmail.snippet
        self.sizeEstimate = gmail.sizeEstimate
        self.subject = headers["subject"] ?? "(no subject)"
        let fromValue = headers["from"] ?? ""
        let parsedSender = GmailDataTransformer.parseContactCore(fromValue)
        self.senderEmail = parsedSender.email
        self.senderName = parsedSender.name == parsedSender.email ? nil : parsedSender.name
        self.toRecipients = Self.encodeRecipients(headers["to"] ?? "")
        self.ccRecipients = Self.encodeRecipients(headers["cc"] ?? "")
        self.bccRecipients = nil // BCC only available for sent messages via raw format
        let replyToValue = headers["reply-to"] ?? fromValue
        self.replyTo = replyToValue
        self.messageIdHeader = headers["message-id"] ?? ""
        self.inReplyTo = headers["in-reply-to"] ?? ""
        self.referencesHeader = headers["references"]
        self.bodyHtml = mime.htmlBody
        self.bodyPlain = mime.plainBody
        self.rawHeaders = Self.encodeHeaders(gmail.payload?.headers)
        self.hasAttachments = mime.hasAttachments
        self.isRead = !(gmail.labelIds?.contains(GmailSystemLabel.unread) ?? false)
        self.isStarred = gmail.labelIds?.contains(GmailSystemLabel.starred) ?? false
        self.isFromMailingList = headers["list-unsubscribe"] != nil || headers["list-id"] != nil
        self.unsubscribeUrl = gmail.unsubscribeURL?.absoluteString
        self.fullBodyFetched = mime.htmlBody != nil || mime.plainBody != nil
        self.bodyFetchAttempts = 0
        self.threadMessageCount = 1
        self.fetchedAt = Date().timeIntervalSince1970
        self.gmailDraftId = nil
        self.attachmentCount = gmail.attachmentParts.count
    }

    // MARK: - Test fixture

    #if DEBUG
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
        r.attachmentCount = 0
        return r
    }
    #endif

    // MARK: - Private helpers

    /// Result of a single-pass MIME tree traversal, collecting body text and attachment info.
    private struct MIMEInfo {
        var htmlBody: String?
        var plainBody: String?
        var hasAttachments: Bool
    }

    /// Traverses the MIME tree exactly once to extract HTML body, plain-text body,
    /// and attachment presence. Replaces three separate recursive traversals
    /// (`extractBody` x2, `collectAttachments`) that previously tripled traversal cost
    /// during bulk sync.
    private static func extractMIMEInfo(from part: GmailMessagePart?) -> MIMEInfo {
        var info = MIMEInfo(htmlBody: nil, plainBody: nil, hasAttachments: false)
        guard let part else { return info }
        traverseMIME(part: part, info: &info)
        return info
    }

    private static func traverseMIME(part: GmailMessagePart, info: inout MIMEInfo) {
        // Check for body content (HTML or plain text)
        if let mimeType = part.mimeType, let data = part.body?.data {
            if mimeType == "text/html", info.htmlBody == nil {
                info.htmlBody = Data(base64URLEncoded: data).flatMap { String(data: $0, encoding: .utf8) }
            } else if mimeType == "text/plain", info.plainBody == nil {
                info.plainBody = Data(base64URLEncoded: data).flatMap { String(data: $0, encoding: .utf8) }
            }
        }

        // Check for attachments: has a non-empty filename + attachmentId, but no Content-ID (inline)
        if let filename = part.filename, !filename.isEmpty, part.body?.attachmentId != nil,
           part.contentID == nil {
            info.hasAttachments = true
        }

        // Recurse into child parts
        for sub in part.parts ?? [] {
            traverseMIME(part: sub, info: &info)
        }
    }

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
    func toEmail(labels: [LabelRecord], tags: EmailTagRecord?, attachments: [AttachmentRecord] = []) -> Email {
        let sender = Contact(
            name: senderName ?? senderEmail ?? "Unknown",
            email: senderEmail ?? ""
        )
        let userLabels = labels.filter { $0.type == "user" }.map { label in
            EmailLabel(
                id: GmailDataTransformer.deterministicUUID(from: label.gmailId),
                name: label.name,
                color: label.bgColor ?? "#e8eaed",
                textColor: label.textColor ?? "#3c4043"
            )
        }
        // Parse recipients from JSON
        let toList = Self.decodeRecipientStrings(toRecipients)
        let ccList = Self.decodeRecipientStrings(ccRecipients)

        // Derive folder from system label IDs in the labels array
        let systemLabelIds = labels.compactMap { $0.type == "system" ? $0.gmailId : nil }
        let folder = GmailDataTransformer.folderFor(labelIDs: systemLabelIds)

        let isDraft = systemLabelIds.contains(GmailSystemLabel.draft)
        let gmailLabelIDs = labels.map { $0.gmailId }

        let attachmentModels = attachments.map { record in
            Attachment(
                name: record.filename ?? "Attachment",
                fileType: Attachment.FileType.from(fileExtension: (record.filename as NSString?)?.pathExtension ?? ""),
                size: record.size.map { GmailDataTransformer.sizeString($0) } ?? "",
                gmailAttachmentId: record.gmailAttachmentId,
                gmailMessageId: record.messageId,
                mimeType: record.mimeType
            )
        }

        let emailTags: EmailTags? = tags.map { record in
            EmailTags(
                needsReply: record.needsReply,
                fyiOnly: record.fyiOnly,
                hasDeadline: record.hasDeadline,
                financial: record.financial
            )
        }

        return Email(
            id: GmailDataTransformer.deterministicUUID(from: gmailId),
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
            attachmentCount: attachmentCount,
            attachments: attachmentModels,
            folder: folder,
            labels: userLabels,
            isDraft: isDraft,
            gmailMessageID: gmailId,
            gmailThreadID: threadId,
            gmailLabelIDs: gmailLabelIDs,
            threadMessageCount: threadMessageCount,
            isFromMailingList: isFromMailingList,
            unsubscribeURL: unsubscribeUrl.flatMap { URL(string: $0) },
            tags: emailTags,
            messageIDHeader: messageIdHeader,
            referencesHeader: referencesHeader
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
        if !isRead { labelIds.append(GmailSystemLabel.unread) }
        if isStarred { labelIds.append(GmailSystemLabel.starred) }

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
        if let referencesHeader { headers.append(GmailHeader(name: "References", value: referencesHeader)) }
        if let url = unsubscribeUrl { headers.append(GmailHeader(name: "List-Unsubscribe", value: url)) }
        return headers
    }

    private func buildBody() -> GmailMessageBody? {
        let bodyContent = bodyHtml ?? bodyPlain
        guard let bodyContent else { return nil }
        // Re-encode as base64url so GmailMessage.htmlBody / plainBody can decode it
        let base64url = Data(bodyContent.utf8).base64URLEncodedString()
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
