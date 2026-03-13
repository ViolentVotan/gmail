import Foundation

// MARK: - Message List

struct GmailMessageListResponse: Codable, Sendable {
    let messages:            [GmailMessageRef]?
    let nextPageToken:       String?
    let resultSizeEstimate:  Int?
}

struct GmailMessageRef: Codable, Sendable {
    let id:       String
    let threadId: String
}

// MARK: - Message

struct GmailMessage: Codable, Sendable {
    let id:           String
    let threadId:     String
    var labelIds:     [String]?
    let snippet:      String?
    let internalDate: String?
    let payload:      GmailMessagePart?
    let sizeEstimate: Int?
    let historyId:    String?
    let raw:          String?   // base64url-encoded RFC 2822 source (format=raw)
}

struct GmailMessagePart: Codable, Sendable {
    let partId:   String?
    let mimeType: String?
    let filename: String?
    let headers:  [GmailHeader]?
    let body:     GmailMessageBody?
    let parts:    [GmailMessagePart]?
}

struct GmailHeader: Codable, Sendable {
    let name:  String
    let value: String
}

struct GmailMessageBody: Codable, Sendable {
    let attachmentId: String?
    let size:         Int
    let data:         String?   // base64url encoded
}

// MARK: - Thread

struct GmailThread: Codable, Sendable {
    let id:        String
    let historyId: String?
    let messages:  [GmailMessage]?
}

// MARK: - History

struct GmailHistoryListResponse: Codable, Sendable {
    let history:       [GmailHistoryRecord]?
    let nextPageToken: String?
    let historyId:     String
}

struct GmailHistoryRecord: Codable, Sendable {
    let id:              String
    let messagesAdded:   [GmailHistoryMessageAdded]?
    let messagesDeleted: [GmailHistoryMessageDeleted]?
    let labelsAdded:     [GmailHistoryLabelAdded]?
    let labelsRemoved:   [GmailHistoryLabelRemoved]?
}

struct GmailHistoryMessageAdded: Codable, Sendable {
    let message: GmailMessageRef
}

struct GmailHistoryMessageDeleted: Codable, Sendable {
    let message: GmailMessageRef
}

struct GmailHistoryLabelAdded: Codable, Sendable {
    let message:  GmailMessageRef
    let labelIds: [String]
}

struct GmailHistoryLabelRemoved: Codable, Sendable {
    let message:  GmailMessageRef
    let labelIds: [String]
}

struct GmailThreadListResponse: Codable, Sendable {
    let threads:            [GmailThreadRef]?
    let nextPageToken:      String?
    let resultSizeEstimate: Int?
}

struct GmailThreadRef: Codable, Sendable {
    let id:        String
    let snippet:   String?
    let historyId: String?
}

// MARK: - Labels

struct GmailLabelListResponse: Codable, Sendable {
    let labels: [GmailLabel]
}

struct GmailLabelColor: Codable, Sendable {
    let textColor:       String?
    let backgroundColor: String?
}

struct GmailLabel: Codable, Identifiable, Sendable {
    let id:              String
    let name:            String
    let type:            String?
    let messagesTotal:   Int?
    let messagesUnread:  Int?
    let threadsTotal:    Int?
    let threadsUnread:   Int?
    let color:           GmailLabelColor?
}

// MARK: - GmailLabel Helpers

extension GmailLabel {
    static let systemLabelIDs: Set<String> = [
        GmailSystemLabel.inbox, GmailSystemLabel.unread, GmailSystemLabel.starred, GmailSystemLabel.important,
        GmailSystemLabel.sent, GmailSystemLabel.draft, GmailSystemLabel.trash, GmailSystemLabel.spam,
        GmailSystemLabel.category_personal, GmailSystemLabel.category_social,
        GmailSystemLabel.category_promotions, GmailSystemLabel.category_updates, GmailSystemLabel.category_forums,
        "CHAT",
        // Star/superstars variants
        "YELLOW_STAR", "ORANGE_STAR", "RED_STAR", "PURPLE_STAR", "BLUE_STAR", "GREEN_STAR",
        "RED_BANG", "ORANGE_GUILLEMET", "YELLOW_BANG",
        "GREEN_CHECK", "BLUE_INFO", "PURPLE_QUESTION"
    ]

    var isSystemLabel: Bool { GmailLabel.systemLabelIDs.contains(id) }

    /// Last path component of the name (e.g. "work/projects" → "projects").
    var displayName: String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    // Stable palette used for labels that have no API colour set.
    private static let colorPalette: [(bg: String, text: String)] = [
        ("#e8f0fe", "#1967d2"),
        ("#fce8e6", "#c5221f"),
        ("#e6f4ea", "#137333"),
        ("#fef7e0", "#b06000"),
        ("#f3e8fd", "#6200ea"),
        ("#fde7f3", "#ad1457"),
        ("#fff3e0", "#e65100"),
        ("#e3f2fd", "#0277bd"),
    ]

    /// Stable hash for palette index — Swift's hashValue is randomised per launch.
    private var stablePaletteIndex: Int {
        Int(stableHash(id) % UInt64(GmailLabel.colorPalette.count))
    }

    var resolvedBgColor: String {
        if let bg = color?.backgroundColor, !bg.isEmpty { return bg }
        return GmailLabel.colorPalette[stablePaletteIndex].bg
    }

    var resolvedTextColor: String {
        if let text = color?.textColor, !text.isEmpty { return text }
        return GmailLabel.colorPalette[stablePaletteIndex].text
    }
}

// MARK: - Profile

struct GmailProfile: Codable, Sendable {
    let emailAddress:  String
    let messagesTotal: Int
    let threadsTotal:  Int
    let historyId:     String
}

// MARK: - Send As / Signature

struct GmailSendAsListResponse: Codable, Sendable {
    let sendAs: [GmailSendAs]
}

struct GmailSendAs: Codable, Identifiable, Sendable {
    var id: String { sendAsEmail }
    let sendAsEmail: String
    let displayName: String?
    let signature:   String?
    let isDefault:   Bool?
    let isPrimary:   Bool?
}


// MARK: - Attachment

struct GmailAttachmentResponse: Codable, Sendable {
    let size: Int
    let data: String    // base64url encoded
}

// MARK: - Draft

struct GmailDraft: Codable, Sendable {
    let id:      String
    let message: GmailMessage?
}

struct GmailDraftListResponse: Codable, Sendable {
    let drafts:             [GmailDraftRef]?
    let nextPageToken:      String?
    let resultSizeEstimate: Int?
}

struct GmailDraftRef: Codable, Sendable {
    let id:      String
    let message: GmailMessageRef?
}

// MARK: - GmailMessage Helpers

extension GmailMessage {
    func header(named name: String) -> String? {
        payload?.headers?.first(where: { $0.name.lowercased() == name.lowercased() })?.value
    }

    var subject:   String { header(named: "Subject") ?? "(no subject)" }
    var from:      String { header(named: "From")    ?? "" }
    var to:        String { header(named: "To")      ?? "" }
    var cc:        String { header(named: "Cc")      ?? "" }
    var replyTo:   String { header(named: "Reply-To") ?? from }
    var messageID: String { header(named: "Message-ID") ?? "" }
    var inReplyTo: String { header(named: "In-Reply-To") ?? "" }

    var date: Date? {
        guard let ms = internalDate, let msInt = Int64(ms) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(msInt) / 1000)
    }

    var isUnread:  Bool { labelIds?.contains(GmailSystemLabel.unread)   ?? false }
    var isStarred: Bool { labelIds?.contains(GmailSystemLabel.starred)  ?? false }
    var isDraft:   Bool { labelIds?.contains(GmailSystemLabel.draft)    ?? false }

    /// True when the message was sent by a mailing list (List-Unsubscribe or List-Id header present).
    var isFromMailingList: Bool {
        header(named: "List-Unsubscribe") != nil || header(named: "List-Id") != nil
    }

    /// Parses the List-Unsubscribe header and returns the best URL (HTTPS preferred over mailto).
    var unsubscribeURL: URL? {
        guard let raw = header(named: "List-Unsubscribe") else { return nil }
        var https: URL? = nil
        var mailto: URL? = nil
        var pos = raw.startIndex
        while let open = raw[pos...].firstIndex(of: "<") {
            let after = raw.index(after: open)
            if let close = raw[after...].firstIndex(of: ">") {
                let entry = String(raw[after..<close]).trimmingCharacters(in: .whitespaces)
                if entry.hasPrefix("http"), https == nil  { https = URL(string: entry) }
                if entry.hasPrefix("mailto"), mailto == nil { mailto = URL(string: entry) }
                pos = raw.index(after: close)
            } else { break }
        }
        return https ?? mailto
    }

    /// True when RFC 8058 one-click unsubscribe via POST is supported.
    var supportsOneClickUnsubscribe: Bool {
        header(named: "List-Unsubscribe-Post") != nil
    }

    /// Recursively extracts text/html body.
    var htmlBody:  String? { extractBody(mimeType: "text/html",  from: payload) }
    var plainBody: String? { extractBody(mimeType: "text/plain", from: payload) }

    var body: String { htmlBody ?? plainBody ?? snippet ?? "" }

    /// Parts that are actual file attachments (requires body.attachmentId — full format only).
    var attachmentParts: [GmailMessagePart] { collectAttachments(from: payload) }

    /// True if any part has a non-empty filename (works even in metadata format where attachmentId may be missing).
    var hasPartsWithFilenames: Bool { hasFilenames(in: payload) }

    private func hasFilenames(in part: GmailMessagePart?) -> Bool {
        guard let part = part else { return false }
        if let filename = part.filename, !filename.isEmpty { return true }
        for sub in part.parts ?? [] { if hasFilenames(in: sub) { return true } }
        return false
    }

    // MARK: - Security / Sender info

    private static let receivedFromRegex = try? NSRegularExpression(pattern: "from\\s+([\\w.-]+)", options: .caseInsensitive)
    private static let dkimDomainRegex   = try? NSRegularExpression(pattern: "\\bd=([^;\\s]+)", options: .caseInsensitive)

    /// Domain from the Return-Path or Received header (who actually sent the email).
    var mailedBy: String? {
        // Try Return-Path first
        if let rp = header(named: "Return-Path") {
            let cleaned = rp.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
            if let at = cleaned.lastIndex(of: "@") {
                let domain = String(cleaned[cleaned.index(after: at)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !domain.isEmpty { return domain }
            }
        }
        // Fallback: first Received header domain
        if let received = header(named: "Received") {
            let range = NSRange(received.startIndex..., in: received)
            if let match = Self.receivedFromRegex?.firstMatch(in: received, range: range),
               let r = Range(match.range(at: 1), in: received) {
                return String(received[r])
            }
        }
        return nil
    }

    /// DKIM signing domain (from DKIM-Signature d= parameter).
    var signedBy: String? {
        guard let dkim = header(named: "DKIM-Signature") else { return nil }
        let range = NSRange(dkim.startIndex..., in: dkim)
        if let match = Self.dkimDomainRegex?.firstMatch(in: dkim, range: range),
           let r = Range(match.range(at: 1), in: dkim) {
            return String(dkim[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Encryption type from Received headers (TLS, STARTTLS, etc.).
    var encryptionInfo: String? {
        guard let received = header(named: "Received") else { return nil }
        let lower = received.lowercased()
        if lower.contains("tls") || lower.contains("starttls") || lower.contains("esmtps") {
            return "Standard encryption (TLS)"
        }
        return nil
    }

    /// The domain part of the From header email.
    var fromDomain: String? {
        let f = from
        // Extract email from "Name <email>" format
        let email: String
        if let open = f.lastIndex(of: "<"), let close = f.lastIndex(of: ">") {
            email = String(f[f.index(after: open)..<close])
        } else {
            email = f
        }
        guard let at = email.lastIndex(of: "@") else { return nil }
        return String(email[email.index(after: at)...]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when mailed-by domain doesn't match the From domain — potential spoofing.
    var isSuspiciousSender: Bool {
        guard let fromD = fromDomain, let mailedD = mailedBy?.lowercased() else { return false }
        return !mailedD.hasSuffix(fromD) && !fromD.hasSuffix(mailedD)
    }

    /// Decodes the raw RFC 2822 source from base64url.
    var rawSource: String? {
        guard let raw = raw else { return nil }
        return Data(base64URLEncoded: raw).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Private helpers

    private func extractBody(mimeType: String, from part: GmailMessagePart?) -> String? {
        guard let part = part else { return nil }
        if part.mimeType == mimeType, let data = part.body?.data {
            return Data(base64URLEncoded: data).flatMap { String(data: $0, encoding: .utf8) }
        }
        for sub in part.parts ?? [] {
            if let body = extractBody(mimeType: mimeType, from: sub) { return body }
        }
        return nil
    }

    /// Parts that are inline images (have Content-ID + attachmentId + image MIME type).
    var inlineParts: [GmailMessagePart] { collectInlineParts(from: payload) }

    private func collectInlineParts(from part: GmailMessagePart?) -> [GmailMessagePart] {
        guard let part = part else { return [] }
        var result: [GmailMessagePart] = []
        if part.contentID != nil, part.body?.attachmentId != nil,
           part.mimeType?.hasPrefix("image/") == true {
            result.append(part)
        }
        for sub in part.parts ?? [] { result += collectInlineParts(from: sub) }
        return result
    }

    private func collectAttachments(from part: GmailMessagePart?) -> [GmailMessagePart] {
        guard let part = part else { return [] }
        var result: [GmailMessagePart] = []
        if let filename = part.filename, !filename.isEmpty, part.body?.attachmentId != nil,
           part.contentID == nil {
            result.append(part)
        }
        for sub in part.parts ?? [] { result += collectAttachments(from: sub) }
        return result
    }
}

// MARK: - GmailMessagePart Helpers

extension GmailMessagePart {
    /// Extracts Content-ID header value, stripping angle brackets.
    var contentID: String? {
        headers?.first(where: { $0.name.lowercased() == "content-id" })?.value
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }
}

// MARK: - Test Fixtures

#if DEBUG
extension GmailMessage {
    /// Creates a minimal test fixture for unit tests.
    static func testFixture(
        id: String = "msg-test",
        threadId: String = "thread-test",
        labelIds: [String] = ["INBOX"],
        subject: String = "Test Subject",
        from: String = "test@example.com",
        snippet: String = "Test snippet"
    ) -> GmailMessage {
        let subjectHeader = GmailHeader(name: "Subject", value: subject)
        let fromHeader = GmailHeader(name: "From", value: from)
        let payload = GmailMessagePart(
            partId: "0",
            mimeType: "text/plain",
            filename: nil,
            headers: [subjectHeader, fromHeader],
            body: GmailMessageBody(attachmentId: nil, size: 0, data: nil),
            parts: nil
        )
        return GmailMessage(
            id: id,
            threadId: threadId,
            labelIds: labelIds,
            snippet: snippet,
            internalDate: String(Int(Date().timeIntervalSince1970 * 1000)),
            payload: payload,
            sizeEstimate: 1024,
            historyId: nil,
            raw: nil
        )
    }
}
#endif
