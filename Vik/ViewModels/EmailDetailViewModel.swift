import AppKit
import SwiftUI
internal import GRDB
import Synchronization

/// Pre-computed HTML content for a thread message, avoiding regex work during SwiftUI rendering.
struct PrecomputedMessageHTML: Equatable, Sendable {
    let fullHTML: String
    let originalHTML: String
    let quotedHTML: String?
}

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
    /// Pre-computed HTML parts for each thread message, avoiding regex work during rendering.
    var precomputedHTMLParts: [String: PrecomputedMessageHTML] = [:]
    var calendarInvite:  CalendarInvite?
    var rsvpInProgress   = false
    /// Matched real calendar event for an email invite (iCalUID lookup).
    var matchedCalendarEvent: CalendarEvent?
    /// Upcoming event context: a meeting with the email sender/recipients within 48h.
    var calendarContextEvent: CalendarEvent?

    /// Tracker-sanitized HTML for the latest message, or nil if no tracker analysis ran.
    var trackerSanitizedHTML: String? {
        guard let result = trackerResult else { return nil }
        return allowTrackers ? result.originalHTML : result.sanitizedHTML
    }

    var blockedTrackerCount: Int { trackerResult?.trackerCount ?? 0 }
    var hasBlockedTrackers: Bool { !allowTrackers && (trackerResult?.hasTrackers ?? false) }
    var groupedTrackers: [TrackerBannerView.TrackerGroup] {
        TrackerBannerView.TrackerGroup.group(from: trackerResult?.trackers ?? [])
    }

    @ObservationIgnored let accountID: String
    @ObservationIgnored let api: any MessageFetching
    @ObservationIgnored var attachmentIndexer: AttachmentIndexer?
    @ObservationIgnored var onMessagesRead: (([String]) -> Void)?
    @ObservationIgnored var mailDatabase: MailDatabase?
    @ObservationIgnored private let backgroundTasks: Mutex<[Task<Void, Never>]> = Mutex([])
    @ObservationIgnored private var calendarInviteTask: Task<Void, Never>?
    @ObservationIgnored private var lastPrecomputedInput: [String: String] = [:]

    // MARK: - Attachment state

    var quickLookURLs: [URL] = []
    var quickLookSelection: URL?
    var downloadingAttachmentIDs: Set<String> = []

    struct BatchProgress: Equatable {
        var completed: Int
        var total: Int
    }
    var batchDownloadProgress: BatchProgress?

    init(accountID: String, api: any MessageFetching = GmailMessageService.shared) {
        self.accountID = accountID
        self.api = api
    }

    deinit {
        backgroundTasks.withLock { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    // MARK: - Load

    func loadThread(id: String) async {
        calendarInviteTask?.cancel()
        calendarInviteTask = nil
        backgroundTasks.withLock { tasks in
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }
        isLoading = true
        error     = nil
        allowTrackers = false
        matchedCalendarEvent = nil
        calendarContextEvent = nil
        defer { isLoading = false }

        resolvedMessageHTML.removeAll()
        precomputedHTMLParts.removeAll()

        // Tier 1: In-memory cache hit — skip DB read and all preprocessing
        let cacheHit = EmailContentCache.shared.get(id)
        if let cached = cacheHit {
            thread = GmailThread(id: id, historyId: nil, messages: cached.messages)
            precomputedHTMLParts = cached.htmlParts
            trackerResult = cached.trackerResult
            resolvedMessageHTML = cached.resolvedMessageHTML
            // Don't return — still proceed to API refresh to check for new messages
        }

        // DB fast path: load thread from local database (skip if Tier 1 hit)
        if cacheHit == nil, let db = mailDatabase {
            let threadMessages = try? await db.dbPool.read { db in
                try MailDatabaseQueries.messagesForThread(id, in: db)
            }
            if let records = threadMessages, !records.isEmpty {
                let allHaveBodies = records.allSatisfy { $0.fullBodyFetched == true }
                let gmailMessages = records.map { $0.toGmailMessage() }

                // Tier 2: Check preprocessed DB columns — zero regex work
                let latestRecord = records.last!
                let versionOK = latestRecord.preprocessingVersion == HTMLPreprocessingPipeline.currentVersion
                if versionOK, latestRecord.preprocessedHtml != nil {
                    if let sanitized = latestRecord.sanitizedHtml,
                       let preprocessed = latestRecord.preprocessedHtml {
                        trackerResult = TrackerResult(
                            sanitizedHTML: sanitized,
                            originalHTML: preprocessed,
                            trackers: []
                        )
                    }
                    thread = GmailThread(id: id, historyId: nil, messages: gmailMessages)

                    for record in records {
                        if let original = record.originalHtml {
                            precomputedHTMLParts[record.gmailId] = PrecomputedMessageHTML(
                                fullHTML: record.preprocessedHtml ?? "",
                                originalHTML: original,
                                quotedHTML: record.quotedHtml
                            )
                        }
                    }

                    if let latestID = gmailMessages.last?.id {
                        let baseHTML = trackerSanitizedHTML ?? gmailMessages.last?.htmlBody ?? ""
                        if !baseHTML.isEmpty { resolvedMessageHTML[latestID] = baseHTML }
                    }
                } else {
                    // Tier 3: Full preprocessing fallback
                    let latestHTML = gmailMessages.last?.htmlBody ?? ""
                    trackerResult = !latestHTML.isEmpty
                        ? await sanitizeOffMainActor(html: latestHTML) : nil
                    thread = GmailThread(id: id, historyId: nil, messages: gmailMessages)
                    if let latestID = gmailMessages.last?.id {
                        let baseHTML = trackerSanitizedHTML ?? latestHTML
                        if !baseHTML.isEmpty { resolvedMessageHTML[latestID] = baseHTML }
                    }
                    precomputeHTMLParts()

                    // Lazy backfill: write preprocessed columns back to DB
                    if allHaveBodies {
                        let recordsToBackfill = records.filter {
                            $0.fullBodyFetched == true && $0.bodyHtml != nil && $0.preprocessedHtml == nil
                        }
                        if !recordsToBackfill.isEmpty {
                            let t = Task<Void, Never>.detached { [db] in
                                try? await db.dbPool.write { dbConn in
                                    for record in recordsToBackfill {
                                        guard let html = record.bodyHtml else { continue }
                                        let r = HTMLPreprocessingPipeline.preprocess(html)
                                        try dbConn.execute(
                                            sql: """
                                                UPDATE messages SET preprocessed_html = ?, sanitized_html = ?,
                                                original_html = ?, quoted_html = ?, preprocessing_version = ?
                                                WHERE gmail_id = ?
                                                """,
                                            arguments: [r.preprocessedHTML, r.sanitizedHTML, r.originalHTML, r.quotedHTML, r.version, record.gmailId]
                                        )
                                    }
                                }
                            }
                            backgroundTasks.withLock { $0.append(t) }
                        }
                    }
                }

                // Calendar detection runs for both Tier 2 and Tier 3
                async let inviteDone: Void = detectCalendarInvite()
                if let latest = gmailMessages.last {
                    async let contextDone: Void = detectCalendarContext(for: latest)
                    _ = await (inviteDone, contextDone)
                } else {
                    _ = await inviteDone
                }

                // CID resolution and read tracking run for both tiers
                if allHaveBodies {
                    let unreadIDs = gmailMessages.filter(\.isUnread).map(\.id)
                    if !unreadIDs.isEmpty {
                        onMessagesRead?(unreadIDs)
                    }
                    if let latest = gmailMessages.last {
                        await resolveInlineImages(for: latest)
                    }
                    if gmailMessages.count > 1 {
                        await resolveInlineImagesForOlderMessages(Array(gmailMessages.dropLast()))
                    }
                }
                precomputeHTMLParts()

                // Populate in-memory cache after DB load
                if let t = thread {
                    EmailContentCache.shared.set(id, content: EmailContentCache.ThreadContent(
                        messages: t.messages ?? [],
                        htmlParts: precomputedHTMLParts,
                        trackerResult: trackerResult,
                        resolvedMessageHTML: resolvedMessageHTML
                    ))
                }
            }
        }

        // Refresh from API
        do {
            let fresh = try await api.getThread(id: id, accountID: accountID)
            let changed = fresh.messages?.count != thread?.messages?.count
                || fresh.messages?.last?.id != thread?.messages?.last?.id
            if changed {
                // Pre-analyze trackers before updating thread (single WebView load).
                let freshHTML = fresh.messages?.last?.htmlBody ?? ""
                trackerResult = !freshHTML.isEmpty
                    ? await sanitizeOffMainActor(html: freshHTML) : nil
                thread = fresh
                if let latest = fresh.messages?.last {
                    let baseHTML = trackerSanitizedHTML ?? latest.htmlBody ?? ""
                    if !baseHTML.isEmpty { resolvedMessageHTML[latest.id] = baseHTML }
                }
                async let inviteDone: Void = detectCalendarInvite()
                if let latest = fresh.messages?.last {
                    async let contextDone: Void = detectCalendarContext(for: latest)
                    _ = await (inviteDone, contextDone)
                    await resolveInlineImages(for: latest)
                } else {
                    _ = await inviteDone
                }
                if let allMessages = fresh.messages, allMessages.count > 1 {
                    await resolveInlineImagesForOlderMessages(Array(allMessages.dropLast()))
                }
                precomputeHTMLParts()
                EmailContentCache.shared.set(id, content: EmailContentCache.ThreadContent(
                    messages: fresh.messages ?? [],
                    htmlParts: precomputedHTMLParts,
                    trackerResult: trackerResult,
                    resolvedMessageHTML: resolvedMessageHTML
                ))
            } else {
                thread = fresh
                precomputeHTMLParts()
                EmailContentCache.shared.set(id, content: EmailContentCache.ThreadContent(
                    messages: fresh.messages ?? [],
                    htmlParts: precomputedHTMLParts,
                    trackerResult: trackerResult,
                    resolvedMessageHTML: resolvedMessageHTML
                ))
            }
            // Passive attachment registration from full-format messages
            if let indexer = attachmentIndexer, let messages = fresh.messages {
                let withAttachments = messages.filter { !$0.attachmentParts.isEmpty }
                if !withAttachments.isEmpty {
                    let t = Task { await indexer.registerFromFullMessages(messages: withAttachments) }
                    backgroundTasks.withLock { $0.append(t) }
                }
            }
            // Mark all unread messages in the thread as read (single batch API call)
            let unreadMessages = (fresh.messages ?? []).filter(\.isUnread)
            if !unreadMessages.isEmpty {
                let unreadIds = unreadMessages.map(\.id)
                try? await api.batchModifyLabels(
                    ids: unreadIds, add: [], remove: [GmailSystemLabel.unread], accountID: accountID
                )
                onMessagesRead?(unreadIds)
            }
        } catch {
            // Keep cached thread if API fails (offline mode)
            if thread == nil { self.error = error.localizedDescription }
        }
    }

    func allowBlockedContent() {
        allowTrackers = true
        // Re-resolve latest message HTML with original (unblocked) content.
        guard let latest = latestMessage else { return }
        let t = Task { await resolveInlineImages(for: latest) }
        backgroundTasks.withLock { $0.append(t) }
    }

    // MARK: - Tracker analysis

    @concurrent private func sanitizeOffMainActor(html: String) async -> TrackerResult {
        let stripped = HTMLPreprocessor.strip(html)
        return TrackerBlockerService.shared.sanitize(html: stripped)
    }

    // MARK: - Calendar invite detection

    private func detectCalendarInvite() async {
        guard let msg = latestMessage,
              let html = msg.htmlBody, !html.isEmpty
        else { calendarInvite = nil; return }

        let parseTask = Task.detached {
            CalendarInviteParser.parse(html: html, subject: msg.subject, sender: msg.from)
        }
        calendarInviteTask = Task { _ = await parseTask.value }
        let parsed = await parseTask.value
        guard !Task.isCancelled else { return }
        guard var invite = parsed else { calendarInvite = nil; return }

        // Restore persisted RSVP status
        if let saved = UserDefaults.standard.string(forKey: rsvpKey(for: msg.id)),
           let status = CalendarInvite.RSVPStatus(rawValue: saved) {
            invite.rsvpStatus = status
        }
        calendarInvite = invite

        // Layer 1: match invite to a real calendar event via iCalUID from email header
        if let db = mailDatabase,
           let uid = msg.header(named: "X-Google-ICSUID") ?? msg.header(named: "X-Google-Calendar-ICS-UID") {
            matchedCalendarEvent = await CalendarIntegrationService.shared.findEventForInvite(
                iCalUID: uid,
                accountID: accountID,
                db: db
            )
        }
    }

    /// Layer 2: find upcoming meetings with email participants and set `calendarContextEvent`.
    private func detectCalendarContext(for message: GmailMessage) async {
        guard let db = mailDatabase else { return }
        // Collect sender + all recipient emails (parse raw RFC 2822 address strings)
        var participantEmails: [String] = []
        for addressField in [message.from, message.to, message.cc] {
            for email in Self.extractEmails(from: addressField) {
                participantEmails.append(email)
            }
        }
        guard !participantEmails.isEmpty else { return }
        let events = await CalendarIntegrationService.shared.findUpcomingEventsWithParticipants(
            emails: participantEmails,
            accountID: accountID,
            db: db
        )
        calendarContextEvent = events.first
    }

    /// Extracts bare email addresses from a comma-separated RFC 2822 address list string.
    private static func extractEmails(from addressList: String) -> [String] {
        guard !addressList.isEmpty else { return [] }
        return addressList.components(separatedBy: ",")
            .map { GmailDataTransformer.parseContactCore($0).email.lowercased() }
            .filter { $0.contains("@") }
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
        let raw = trackerSanitizedHTML ?? message.htmlBody ?? ""
        // trackerSanitizedHTML is already preprocessed via sanitizeOffMainActor.
        // Raw htmlBody needs explicit preprocessing.
        let baseHTML: String
        if trackerSanitizedHTML != nil {
            baseHTML = raw
        } else {
            baseHTML = await Task.detached { HTMLPreprocessor.strip(raw) }.value
        }
        guard !Task.isCancelled else { return }
        guard !baseHTML.isEmpty else { return }
        guard !message.inlineParts.isEmpty else {
            if resolvedMessageHTML[message.id] != baseHTML {
                resolvedMessageHTML[message.id] = baseHTML
            }
            return
        }
        let resolved = await Self.replaceCIDReferences(in: baseHTML, message: message, accountID: accountID, api: api)
        if resolvedMessageHTML[message.id] != resolved {
            resolvedMessageHTML[message.id] = resolved
        }
        precomputeHTMLParts()
        if let threadID = thread?.id {
            let resolved = resolvedMessageHTML
            let parts = precomputedHTMLParts
            EmailContentCache.shared.update(threadID) { content in
                content.resolvedMessageHTML = resolved
                content.htmlParts = parts
            }
        }
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
        precomputeHTMLParts()
        if let threadID = thread?.id {
            let resolved = resolvedMessageHTML
            let parts = precomputedHTMLParts
            EmailContentCache.shared.update(threadID) { content in
                content.resolvedMessageHTML = resolved
                content.htmlParts = parts
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

    // MARK: - Label Suggestions

    func generateLabelSuggestions(for email: Email, existingLabels: [GmailLabel]) async -> [LabelSuggestion] {
        await LabelSuggestionService.shared.generateSuggestions(for: email, existingLabels: existingLabels)
    }

    // MARK: - HTML Precomputation

    /// Pre-computes full HTML and quoted-content-stripped parts for all thread messages.
    /// Call after resolvedMessageHTML is updated so rendering can skip regex work.
    /// Skips messages whose input HTML hasn't changed since last computation.
    private func precomputeHTMLParts() {
        guard let messages = thread?.messages else { return }
        for message in messages {
            let inputHTML = resolvedMessageHTML[message.id] ?? message.htmlBody ?? ""
            if lastPrecomputedInput[message.id] == inputHTML,
               precomputedHTMLParts[message.id] != nil { continue }
            let html = GmailThreadMessageView.computeFullHTML(
                message: message,
                resolvedHTML: resolvedMessageHTML[message.id]
            )
            guard !html.isEmpty else { continue }
            let parts = GmailThreadMessageView.stripQuotedHTML(html)
            precomputedHTMLParts[message.id] = PrecomputedMessageHTML(
                fullHTML: html,
                originalHTML: parts.original,
                quotedHTML: parts.quoted
            )
            lastPrecomputedInput[message.id] = inputHTML
        }
    }

    // MARK: - Derived content

    /// Current label IDs from the latest full message, falling back to email summary.
    func currentLabelIDs(fallback: [String]) -> [String] {
        latestMessage?.labelIds ?? fallback
    }

    // MARK: - Compose helpers

    // MARK: Static compose mode factories (no instance context required)

    static func quotedHTML(for email: Email, latestHTMLBody: String? = nil) -> String {
        let original = latestHTMLBody ?? email.body
        let safeName = email.sender.name.htmlEscaped
        return "<br><br><blockquote style='border-left:2px solid #ccc;margin-left:4px;padding-left:8px;color:#555;'><p><b>\(safeName)</b> wrote:</p>\(original)</blockquote>"
    }

    static func replyMode(for email: Email, latestHTMLBody: String? = nil) -> ComposeMode {
        let sub = email.subject.withReplyPrefix
        return .reply(to: email.sender.email, subject: sub, quotedBody: quotedHTML(for: email, latestHTMLBody: latestHTMLBody),
                      replyToMessageID: email.gmailMessageID ?? "", threadID: email.gmailThreadID ?? "",
                      parentMessageID: email.messageIDHeader, parentReferences: email.referencesHeader)
    }

    static func replyAllMode(for email: Email, latestHTMLBody: String? = nil, currentUserEmail: String? = nil) -> ComposeMode {
        let sub = email.subject.withReplyPrefix
        var toRecipients = email.recipients.map(\.email)
        if let userEmail = currentUserEmail?.lowercased() {
            toRecipients = toRecipients.filter { $0.lowercased() != userEmail }
        }
        let toField = ([email.sender.email] + toRecipients).joined(separator: ", ")
        return .replyAll(to: toField, cc: email.cc.map(\.email).joined(separator: ", "),
                         subject: sub, quotedBody: quotedHTML(for: email, latestHTMLBody: latestHTMLBody),
                         replyToMessageID: email.gmailMessageID ?? "", threadID: email.gmailThreadID ?? "",
                         parentMessageID: email.messageIDHeader, parentReferences: email.referencesHeader)
    }

    static func forwardMode(for email: Email, latestHTMLBody: String? = nil) -> ComposeMode {
        let sub = email.subject.withForwardPrefix
        return .forward(subject: sub, quotedBody: quotedHTML(for: email, latestHTMLBody: latestHTMLBody))
    }

    // MARK: Instance wrappers (use latestMessage context for accurate quoted body)

    func replyMode(email: Email) -> ComposeMode {
        Self.replyMode(for: email, latestHTMLBody: latestMessage?.htmlBody)
    }

    func replyAllMode(email: Email) -> ComposeMode {
        let userEmail = AccountStore.shared.accounts.first(where: { $0.id == accountID })?.email
        return Self.replyAllMode(for: email, latestHTMLBody: latestMessage?.htmlBody, currentUserEmail: userEmail)
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

    // MARK: - Attachment temp file operations

    /// Downloads attachment data, writes to temp file, returns URL.
    /// Checks TemporaryFileManager cache first; checks NetworkMonitor if cache miss.
    func prepareAttachmentTempFile(
        _ attachment: Attachment,
        part: GmailMessagePart,
        messageID: String
    ) async -> URL? {
        let attachmentID = attachment.gmailAttachmentId ?? attachment.id.uuidString

        // Check cache first
        if let cached = await TemporaryFileManager.shared.cachedURL(for: attachmentID) {
            return cached
        }

        // Check connectivity
        guard NetworkMonitor.isReachable else {
            ToastManager.shared.show(message: "You're offline — attachment not available", type: .error)
            return nil
        }

        downloadingAttachmentIDs.insert(attachmentID)
        defer { downloadingAttachmentIDs.remove(attachmentID) }

        do {
            let data = try await downloadAttachment(messageID: messageID, part: part)
            return try await TemporaryFileManager.shared.tempFile(
                for: attachmentID,
                messageID: messageID,
                filename: attachment.name,
                data: data
            )
        } catch {
            ToastManager.shared.show(message: "Download failed: \(error.localizedDescription)", type: .error)
            return nil
        }
    }

    /// Opens Quick Look for a specific attachment, preparing all sibling URLs for gallery nav.
    func quickLookAttachment(
        _ attachment: Attachment,
        part: GmailMessagePart,
        message: GmailMessage
    ) async {
        guard let url = await prepareAttachmentTempFile(attachment, part: part, messageID: message.id) else { return }

        // Prepare all sibling attachment URLs for gallery navigation
        var urls: [URL] = []
        for siblingPart in message.attachmentParts {
            let siblingAttachment = GmailDataTransformer.makeAttachment(from: siblingPart, messageId: message.id)
            let siblingID = siblingAttachment.gmailAttachmentId ?? siblingAttachment.id.uuidString
            if let cached = await TemporaryFileManager.shared.cachedURL(for: siblingID) {
                urls.append(cached)
            }
        }

        // Ensure the selected URL is in the list
        if !urls.contains(url) { urls.insert(url, at: 0) }

        quickLookURLs = urls
        quickLookSelection = url
    }

    /// Downloads and opens attachment in its default app via NSWorkspace.
    func openAttachmentInDefaultApp(
        _ attachment: Attachment,
        part: GmailMessagePart,
        messageID: String
    ) async {
        guard let url = await prepareAttachmentTempFile(attachment, part: part, messageID: messageID) else { return }
        FileUtils.setQuarantine(on: url)
        NSWorkspace.shared.open(url)
    }

    /// Downloads all attachments for a message and saves to a user-selected directory.
    func saveAllAttachments(for message: GmailMessage) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save All"
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let pairs = attachmentPairsForMessage(message)
        let total = pairs.count
        batchDownloadProgress = BatchProgress(completed: 0, total: total)

        // Capture Sendable values before entering TaskGroup to avoid
        // capturing @MainActor-isolated self inside concurrent tasks.
        let api = self.api
        let acctID = self.accountID
        let msgID = message.id

        var succeeded = 0
        var completed = 0
        await withTaskGroup(of: Bool.self) { group in
            for (attachment, part) in pairs {
                guard let part, let attachmentID = part.body?.attachmentId else { continue }
                let filename = attachment.name
                group.addTask {
                    do {
                        let data = try await api.getAttachment(
                            messageID: msgID, attachmentID: attachmentID, accountID: acctID
                        )
                        let uniqueName = FileUtils.uniqueFilename(for: filename, in: directory)
                        let fileURL = directory.appendingPathComponent(uniqueName)
                        try data.write(to: fileURL)
                        FileUtils.setQuarantine(on: fileURL)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            for await success in group {
                if success { succeeded += 1 }
                completed += 1
                batchDownloadProgress = BatchProgress(completed: completed, total: total)
            }
        }

        batchDownloadProgress = nil

        if succeeded == total {
            ToastManager.shared.show(message: "Saved \(total) attachments", type: .success)
        } else {
            ToastManager.shared.show(
                message: "Saved \(succeeded) of \(total) attachments. \(total - succeeded) failed.",
                type: .error
            )
        }
    }

    /// Quick Look version — used by email detail view.
    func loadAndPreview(
        attachment: Attachment,
        part: GmailMessagePart,
        message: GmailMessage
    ) async {
        await quickLookAttachment(attachment, part: part, message: message)
    }

    // MARK: - Convenience

    var messages: [GmailMessage] { thread?.messages ?? [] }
    var latestMessage: GmailMessage? { messages.last }
}
