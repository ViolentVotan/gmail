import SwiftUI
import GRDB

/// Drives the email detail / thread view.
@Observable
@MainActor
final class EmailDetailViewModel {
    var thread:          GmailThread?
    var isLoading        = false
    var error:           String?
    var trackerResult:   TrackerResult?
    var allowTrackers    = false
    /// Resolved inline-image HTML for each thread message (keyed by message ID).
    var resolvedMessageHTML: [String: String] = [:]
    var calendarInvite:  CalendarInvite?
    var rsvpInProgress   = false

    /// Tracker-sanitized HTML for the latest message, or nil if no tracker analysis ran.
    var trackerSanitizedHTML: String? {
        guard let result = trackerResult else { return nil }
        return allowTrackers ? result.originalHTML : result.sanitizedHTML
    }

    var blockedTrackerCount: Int { trackerResult?.trackerCount ?? 0 }
    var hasBlockedTrackers: Bool { !allowTrackers && (trackerResult?.hasTrackers ?? false) }

    @ObservationIgnored let accountID: String
    @ObservationIgnored private let api: any MessageFetching
    @ObservationIgnored var attachmentIndexer: AttachmentIndexer?
    @ObservationIgnored var onMessagesRead: (([String]) -> Void)?
    @ObservationIgnored var mailDatabase: MailDatabase?
    @ObservationIgnored nonisolated(unsafe) private var backgroundTasks: [Task<Void, Never>] = []

    init(accountID: String, api: any MessageFetching = GmailMessageService.shared) {
        self.accountID = accountID
        self.api = api
    }

    deinit {
        backgroundTasks.forEach { $0.cancel() }
    }

    // MARK: - Load

    func loadThread(id: String) async {
        backgroundTasks.forEach { $0.cancel() }
        backgroundTasks.removeAll()
        isLoading = true
        error     = nil
        allowTrackers = false
        defer { isLoading = false }

        resolvedMessageHTML.removeAll()

        // DB fast path: load thread from local database (instant)
        if let db = mailDatabase {
            let threadMessages = try? await db.dbPool.read { db in
                try MailDatabaseQueries.messagesForThread(id, in: db)
            }
            if let records = threadMessages, !records.isEmpty {
                let allHaveBodies = records.allSatisfy { $0.fullBodyFetched }
                let gmailMessages = records.map { $0.toGmailMessage() }
                thread = GmailThread(id: id, historyId: nil, messages: gmailMessages)
                await analyzeTrackers()
                detectCalendarInvite()
                if allHaveBodies {
                    if let latest = gmailMessages.last {
                        await resolveInlineImages(for: latest)
                    }
                    if gmailMessages.count > 1 {
                        await resolveInlineImagesForOlderMessages(Array(gmailMessages.dropLast()))
                    }
                }
            }
        }

        // Refresh from API
        do {
            let fresh = try await api.getThread(id: id, accountID: accountID)
            thread = fresh
            await analyzeTrackers()
            detectCalendarInvite()
            if let latest = fresh.messages?.last {
                await resolveInlineImages(for: latest)
            }
            // Resolve inline images for older thread messages
            if let allMessages = fresh.messages, allMessages.count > 1 {
                await resolveInlineImagesForOlderMessages(Array(allMessages.dropLast()))
            }
            // Passive attachment registration from full-format messages
            if let indexer = attachmentIndexer, let messages = fresh.messages {
                let withAttachments = messages.filter { !$0.attachmentParts.isEmpty }
                if !withAttachments.isEmpty {
                    let t = Task { await indexer.registerFromFullMessages(messages: withAttachments) }
                    backgroundTasks.append(t)
                }
            }
            // Mark all unread messages in the thread as read (concurrently)
            let unreadMessages = (fresh.messages ?? []).filter(\.isUnread)
            if !unreadMessages.isEmpty {
                await withTaskGroup(of: Void.self) { group in
                    for message in unreadMessages {
                        group.addTask { [accountID, api] in
                            try? await api.markAsRead(id: message.id, accountID: accountID)
                        }
                    }
                }
                onMessagesRead?(unreadMessages.map(\.id))
            }
        } catch {
            // Keep cached thread if API fails (offline mode)
            if thread == nil { self.error = error.localizedDescription }
        }
    }

    func allowBlockedContent() {
        allowTrackers = true
    }

    // MARK: - Tracker analysis

    private func analyzeTrackers() async {
        guard let html = latestMessage?.htmlBody, !html.isEmpty else {
            trackerResult = nil
            return
        }
        let result = await Task.detached {
            TrackerBlockerService.shared.sanitize(html: html)
        }.value
        trackerResult = result
    }

    // MARK: - Calendar invite detection

    private func detectCalendarInvite() {
        guard let msg = latestMessage,
              let html = msg.htmlBody, !html.isEmpty
        else { calendarInvite = nil; return }

        guard var invite = CalendarInviteParser.parse(
            html: html,
            subject: msg.subject,
            sender: msg.from
        ) else { calendarInvite = nil; return }

        // Restore persisted RSVP status
        if let saved = UserDefaults.standard.string(forKey: rsvpKey(for: msg.id)),
           let status = CalendarInvite.RSVPStatus(rawValue: saved) {
            invite.rsvpStatus = status
        }
        calendarInvite = invite
    }

    func sendRSVP(_ status: CalendarInvite.RSVPStatus) async {
        guard var invite = calendarInvite else { return }
        guard status != invite.rsvpStatus else { return }

        let url: URL?
        switch status {
        case .accepted: url = invite.acceptURL
        case .declined: url = invite.declineURL
        case .maybe:    url = invite.maybeURL
        case .pending:  return
        }
        guard let rsvpURL = url else { return }

        rsvpInProgress = true
        let success = await CalendarInviteParser.sendRSVP(url: rsvpURL)
        rsvpInProgress = false

        if success {
            invite.rsvpStatus = status
            calendarInvite = invite

            // Persist
            if let msgID = latestMessage?.id {
                UserDefaults.standard.set(status.rawValue, forKey: rsvpKey(for: msgID))
            }

            let message: String
            switch status {
            case .accepted: message = "Invitation accepted"
            case .declined: message = "Invitation declined"
            case .maybe:    message = "Responded maybe"
            case .pending:  return
            }
            ToastManager.shared.show(message: message, type: .success)
        } else {
            ToastManager.shared.show(message: "Failed to send RSVP", type: .error)
        }
    }

    private func rsvpKey(for messageID: String) -> String {
        "rsvp_\(accountID)_\(messageID)"
    }

    // MARK: - Inline Image Resolution

    /// Downloads inline CID images and replaces cid: references with data: URIs in the HTML.
    private func resolveInlineImages(for message: GmailMessage) async {
        guard !message.inlineParts.isEmpty else { return }
        let baseHTML = trackerSanitizedHTML ?? message.htmlBody ?? ""
        guard !baseHTML.isEmpty else { return }
        resolvedMessageHTML[message.id] = await Self.replaceCIDReferences(in: baseHTML, message: message, accountID: accountID, api: api)
    }

    /// Resolves inline CID images for older thread messages in parallel and stores results per message ID.
    private func resolveInlineImagesForOlderMessages(_ messages: [GmailMessage]) async {
        let accountID = self.accountID
        let api = self.api
        await withTaskGroup(of: (String, String).self) { group in
            for message in messages {
                guard !message.inlineParts.isEmpty else { continue }
                guard let baseHTML = message.htmlBody, !baseHTML.isEmpty else { continue }

                group.addTask {
                    let result = await Self.replaceCIDReferences(in: baseHTML, message: message, accountID: accountID, api: api)
                    return (message.id, result)
                }
            }
            for await (messageID, html) in group {
                resolvedMessageHTML[messageID] = html
            }
        }
    }

    /// Shared helper: downloads inline CID attachments and replaces cid: references with data: URIs.
    @concurrent private static func replaceCIDReferences(in html: String, message: GmailMessage, accountID: String, api: any MessageFetching) async -> String {
        var result = html
        await withTaskGroup(of: (String, String, Data?).self) { group in
            for part in message.inlineParts {
                guard let cid = part.contentID,
                      let attachmentID = part.body?.attachmentId,
                      let mime = part.mimeType else { continue }
                group.addTask {
                    let data = try? await api.getAttachment(
                        messageID: message.id,
                        attachmentID: attachmentID,
                        accountID: accountID
                    )
                    return (cid, mime, data)
                }
            }
            for await (cid, mime, data) in group {
                guard let data else { continue }
                let dataURI = "data:\(mime);base64,\(data.base64EncodedString())"
                result = result.replacingOccurrences(of: "cid:\(cid)", with: dataURI)
            }
        }
        return result
    }

    // MARK: - Attachments

    func downloadAttachment(messageID: String, part: GmailMessagePart) async throws -> Data {
        guard let attachmentID = part.body?.attachmentId else {
            throw GmailAPIError.decodingError(URLError(.badServerResponse))
        }
        return try await api.getAttachment(
            messageID:    messageID,
            attachmentID: attachmentID,
            accountID:    accountID
        )
    }

    // MARK: - Label mutation (optimistic local update)

    func updateLabelIDs(_ labelIDs: [String]) {
        guard let current = thread, let msgs = current.messages, let lastID = msgs.last?.id else { return }
        var updated = msgs
        if let idx = updated.firstIndex(where: { $0.id == lastID }) {
            updated[idx].labelIds = labelIDs
        }
        thread = GmailThread(id: current.id, historyId: current.historyId, messages: updated)
    }

    /// Optimistically toggles the STARRED label on the latest message.
    func toggleStar() {
        guard var labelIDs = latestMessage?.labelIds else { return }
        if labelIDs.contains(GmailSystemLabel.starred) {
            labelIDs.removeAll { $0 == GmailSystemLabel.starred }
        } else {
            labelIDs.append(GmailSystemLabel.starred)
        }
        updateLabelIDs(labelIDs)
    }

    // MARK: - Quick Replies

    func generateQuickReplies(for email: Email) async -> [String] {
        await QuickReplyService.shared.generateReplies(for: email)
    }

    // MARK: - Smart Reply Suggestions

    var smartReplySuggestions: [String] = []

    func loadSmartReplies(for email: Email) {
        guard let threadId = email.gmailThreadID else { return }
        if let cached = SmartReplyProvider.shared.cachedReplies(for: threadId) {
            smartReplySuggestions = cached
            return
        }
        let t = Task {
            let replies = await SmartReplyProvider.shared.generateReplies(
                subject: email.subject,
                senderName: email.sender.name,
                body: email.body,
                threadId: threadId
            )
            smartReplySuggestions = replies
        }
        backgroundTasks.append(t)
    }

    // MARK: - Label Suggestions

    func generateLabelSuggestions(for email: Email, existingLabels: [GmailLabel]) async -> [LabelSuggestion] {
        await LabelSuggestionService.shared.generateSuggestions(for: email, existingLabels: existingLabels)
    }

    // MARK: - Derived content

    /// Current label IDs from the latest full message, falling back to email summary.
    func currentLabelIDs(fallback: [String]) -> [String] {
        latestMessage?.labelIds ?? fallback
    }

    // MARK: - Compose helpers

    func quotedHTML(email: Email) -> String {
        let original = latestMessage?.htmlBody ?? email.body
        let safeName = Self.htmlEscape(email.sender.name)
        return "<br><br><blockquote style='border-left:2px solid #ccc;margin-left:4px;padding-left:8px;color:#555;'><p><b>\(safeName)</b> wrote:</p>\(original)</blockquote>"
    }

    // MARK: Static compose mode factories (no instance context required)

    static func quotedHTML(for email: Email, latestHTMLBody: String? = nil) -> String {
        let original = latestHTMLBody ?? email.body
        let safeName = htmlEscape(email.sender.name)
        return "<br><br><blockquote style='border-left:2px solid #ccc;margin-left:4px;padding-left:8px;color:#555;'><p><b>\(safeName)</b> wrote:</p>\(original)</blockquote>"
    }

    /// HTML-escapes a string to prevent XSS when interpolating into HTML.
    private static func htmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func replyMode(for email: Email, latestHTMLBody: String? = nil) -> ComposeMode {
        let sub = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
        return .reply(to: email.sender.email, subject: sub, quotedBody: quotedHTML(for: email, latestHTMLBody: latestHTMLBody),
                      replyToMessageID: email.gmailMessageID ?? "", threadID: email.gmailThreadID ?? "")
    }

    static func replyAllMode(for email: Email, latestHTMLBody: String? = nil) -> ComposeMode {
        let sub = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
        let toField = ([email.sender.email] + email.recipients.map(\.email)).joined(separator: ", ")
        return .replyAll(to: toField, cc: email.cc.map(\.email).joined(separator: ", "),
                         subject: sub, quotedBody: quotedHTML(for: email, latestHTMLBody: latestHTMLBody),
                         replyToMessageID: email.gmailMessageID ?? "", threadID: email.gmailThreadID ?? "")
    }

    static func forwardMode(for email: Email, latestHTMLBody: String? = nil) -> ComposeMode {
        let sub = email.subject.hasPrefix("Fwd:") ? email.subject : "Fwd: \(email.subject)"
        return .forward(subject: sub, quotedBody: quotedHTML(for: email, latestHTMLBody: latestHTMLBody))
    }

    // MARK: Instance wrappers (use latestMessage context for accurate quoted body)

    func replyMode(email: Email) -> ComposeMode {
        Self.replyMode(for: email, latestHTMLBody: latestMessage?.htmlBody)
    }

    func replyAllMode(email: Email) -> ComposeMode {
        let sub = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
        let extras = email.recipients.map(\.email).filter { $0 != (latestMessage?.to ?? email.recipients.first?.email ?? "") }
        let toField = ([email.sender.email] + extras).joined(separator: ", ")
        return .replyAll(to: toField, cc: email.cc.map(\.email).joined(separator: ", "),
                         subject: sub, quotedBody: quotedHTML(email: email),
                         replyToMessageID: email.gmailMessageID ?? "", threadID: email.gmailThreadID ?? "")
    }

    func forwardMode(email: Email) -> ComposeMode {
        Self.forwardMode(for: email, latestHTMLBody: latestMessage?.htmlBody)
    }

    // MARK: - Label suggestion application

    func applyLabelSuggestion(
        _ suggestion: LabelSuggestion,
        allLabels: [GmailLabel],
        fallbackLabelIDs: [String],
        onCreateAndAddLabel: ((String, @escaping (String?) -> Void) -> Void)?,
        onAddLabel: ((String) -> Void)?
    ) {
        if suggestion.isNew {
            onCreateAndAddLabel?(suggestion.name) { _ in }
        } else if let label = allLabels.first(where: { $0.displayName == suggestion.name }) {
            var newIDs = currentLabelIDs(fallback: fallbackLabelIDs)
            newIDs.append(label.id)
            updateLabelIDs(newIDs)
            onAddLabel?(label.id)
        }
    }

    // MARK: - Attachment preview & download (orchestration)

    func loadAndPreview(
        attachment: Attachment,
        part: GmailMessagePart,
        messageID: String,
        onPreviewAttachment: ((Data?, String, Attachment.FileType) -> Void)?
    ) async {
        onPreviewAttachment?(nil, attachment.name, attachment.fileType)
        guard let data = try? await downloadAttachment(messageID: messageID, part: part) else { return }
        onPreviewAttachment?(data, attachment.name, attachment.fileType)
    }

    func downloadAndSave(
        attachment: Attachment,
        part: GmailMessagePart,
        messageID: String
    ) async -> Data? {
        do {
            return try await downloadAttachment(messageID: messageID, part: part)
        } catch {
            ToastManager.shared.show(message: "Download failed: \(error.localizedDescription)", type: .error)
            return nil
        }
    }

    /// Attachment + part tuples for a specific message.
    func attachmentPairsForMessage(_ message: GmailMessage) -> [(Attachment, GmailMessagePart?)] {
        message.attachmentParts.map { part in
            (GmailDataTransformer.makeAttachment(from: part, messageId: message.id), part)
        }
    }

    // MARK: - Convenience

    var messages: [GmailMessage] { thread?.messages ?? [] }
    var latestMessage: GmailMessage? { messages.last }

    /// All thread messages in chronological order (oldest first).
    /// Uses Gmail API's native array order — already sorted by internalDate ascending.
    var allMessagesChronological: [GmailMessage] { messages }
}
