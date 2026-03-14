import GRDB
private import os
import SwiftUI

/// A message with its eagerly-loaded labels and optional tag.
/// Used to decode GRDB association-prefetched results.
private struct MessageWithAssociations: Decodable, FetchableRecord {
    var message: MessageRecord
    var labels: [LabelRecord]
    var tags: EmailTagRecord?
    var attachments: [AttachmentRecord]
}

/// Drives the email list for a given account and folder.
@Observable
@MainActor
final class MailboxViewModel {
    var messages:      [GmailMessage] = [] { didSet { recomputeEmails() } }
    var isLoading      = false
    var error:         String?
    var nextPageToken: String?
    var labels:                [GmailLabel] = [] { didSet { recomputeEmails() } }
    var sendAsAliases:         [GmailSendAs] = []
    var readIDs:               Set<String> = []
    var categoryUnreadCounts:  [InboxCategory: Int] = [:]
    /// Set by `restoreOptimistically` so the UI can re-select the restored email.
    var lastRestoredMessageID: String?
    private(set) var emails: [Email] = []

    var priorityFilterEnabled: Bool = false

    var accountID: String
    var attachmentIndexer: AttachmentIndexer? {
        didSet { fetchService.attachmentIndexer = attachmentIndexer }
    }
    private var currentLabelIDs: [String] = [GmailSystemLabel.inbox]
    private var currentQuery:    String?
    private var suppressRecompute = false

    // MARK: - Services

    private(set) var mailDatabase: MailDatabase? {
        didSet { fetchService.mailDatabase = mailDatabase }
    }
    private(set) var backgroundSyncer: BackgroundSyncer?

    /// Update the mail database for this view model.
    func setMailDatabase(_ db: MailDatabase?) {
        self.mailDatabase = db
    }

    /// Update the background syncer for this view model.
    func setBackgroundSyncer(_ syncer: BackgroundSyncer?) {
        self.backgroundSyncer = syncer
    }

    private(set) var syncProgressManager: SyncProgressManager?

    func setSyncProgressManager(_ manager: SyncProgressManager) {
        self.syncProgressManager = manager
    }

    nonisolated private static let logger = Logger(subsystem: "com.vikingz.serif", category: "Mailbox")
    private let api: MessageFetching
    private let fetchService: MessageFetchService
    private let labelService: LabelSyncService
    private let historyService: HistorySyncService
    @ObservationIgnored nonisolated(unsafe) private var messageObservation: (any DatabaseCancellable)?
    @ObservationIgnored nonisolated(unsafe) private var enrichmentTask: Task<Void, Never>?

    init(
        accountID: String,
        api: MessageFetching = GmailMessageService.shared
    ) {
        self.accountID = accountID
        self.api = api
        self.fetchService   = MessageFetchService(api: api)
        self.labelService   = LabelSyncService()
        self.historyService = HistorySyncService(api: api)
        // Wire up the makeEmail closure for background analysis.
        fetchService.makeEmail = { [weak self] msg in
            guard let self else {
                return Email(sender: Contact(name: "", email: ""), subject: "", body: "")
            }
            return self.makeEmail(from: msg)
        }
        fetchService.accountID = accountID
    }

    deinit {
        messageObservation?.cancel()
        enrichmentTask?.cancel()
    }

    // MARK: - GmailMessage → Email (cached)

    /// Recomputes the `emails` array from `messages` and `labels`.
    /// Called automatically via `didSet` on both properties.
    private func recomputeEmails() {
        guard !suppressRecompute else { return }
        let grouped = Dictionary(grouping: messages) { $0.threadId }
        let representatives: [(GmailMessage, Int)] = grouped.map { (_, msgs) in
            let sorted = msgs.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return (sorted[0], msgs.count)
        }
        emails = representatives
            .sorted { ($0.0.date ?? .distantPast) > ($1.0.date ?? .distantPast) }
            .map { (msg, count) in
                var email = makeEmail(from: msg)
                email.threadMessageCount = count
                return email
            }
    }

    // MARK: - Database Observation

    func startObservingLabel(_ labelId: String) {
        messageObservation?.cancel()
        guard let db = mailDatabase else { return }
        // Use GRDB association prefetching: 4 queries instead of N+1.
        // Query 1: SELECT m.* FROM messages … (filtered by label)
        // Query 2: SELECT l.* FROM labels WHERE … IN (...) (batch)
        // Query 3: SELECT t.* FROM email_tags WHERE … IN (...) (batch)
        // Query 4: SELECT a.* FROM attachments WHERE … IN (...) (batch)
        let request = MessageRecord
            .joining(required: MessageRecord.messageLabels
                .filter(Column("label_id") == labelId))
            .including(all: MessageRecord.labels)
            .including(optional: MessageRecord.tags)
            .including(all: MessageRecord.attachments)
            .order(Column("internal_date").desc)
            .limit(200)
            .asRequest(of: MessageWithAssociations.self)
        let observation = ValueObservation.tracking { db in
            try request.fetchAll(db)
        }
        messageObservation = observation.start(
            in: db.dbPool,
            onError: { [weak self] error in
                self?.error = "Database observation failed: \(error.localizedDescription)"
            },
            onChange: { [weak self] enrichedRecords in
                self?.handleDatabaseUpdate(enrichedRecords, from: db)
            }
        )
    }

    private func handleDatabaseUpdate(_ records: [MessageWithAssociations], from db: MailDatabase) {
        // Stale check: ignore updates from a previous account's database
        guard db === mailDatabase else { return }
        enrichmentTask?.cancel()
        enrichmentTask = Task {
            let threadEmails = Self.threadedEmails(from: records)
            guard !Task.isCancelled else { return }
            guard db === self.mailDatabase else { return }
            // Guard against empty results when the observation returned non-empty records
            if threadEmails.isEmpty && !records.isEmpty { return }
            self.emails = threadEmails
        }
    }

    /// Convert association-prefetched records into threaded Email models.
    /// Pure computation — no database access needed.
    private static func threadedEmails(from records: [MessageWithAssociations]) -> [Email] {
        let emails = records.map { row in
            row.message.toEmail(labels: row.labels, tags: row.tags, attachments: row.attachments)
        }
        let grouped = Dictionary(grouping: emails) { $0.gmailThreadID ?? $0.gmailMessageID ?? $0.id.uuidString }
        return grouped.values.compactMap { threadEmails -> Email? in
            var latest = threadEmails.sorted { $0.date > $1.date }.first
            latest?.threadMessageCount = threadEmails.count
            return latest
        }.sorted { $0.date > $1.date }
    }

    // MARK: - Load

    /// Cancels any in-flight fetch and starts a new folder load.
    func loadFolder(labelIDs: [String], query: String? = nil) async {
        // DB fast path: serve from local database instantly
        if query == nil, let labelId = labelIDs.first, mailDatabase != nil {
            startObservingLabel(labelId)
        }

        let isFolderChange = labelIDs != currentLabelIDs || query != currentQuery
        currentLabelIDs = labelIDs
        currentQuery    = query
        cancelActiveFetch()
        let gen = fetchService.nextGeneration()
        fetchService.setActiveFetchTask(Task {
            await self.performFetch(reset: true, clearFirst: isFolderChange, generation: gen)
        })
        await fetchService.awaitActiveFetch()
    }

    /// Cancels any in-flight fetch and starts a new search.
    func search(query: String) async {
        let newQuery = query.isEmpty ? nil : query
        let isNewQuery = newQuery != currentQuery
        currentQuery = newQuery

        // FTS fast path: search local database first for instant results
        if let q = newQuery, let db = mailDatabase {
            messageObservation?.cancel()
            messageObservation = nil
            let localResults = await Self.localSearch(query: q, db: db)
            if !localResults.isEmpty {
                emails = localResults
            }
        }

        cancelActiveFetch()
        let gen = fetchService.nextGeneration()
        fetchService.setActiveFetchTask(Task {
            await self.performFetch(reset: true, clearFirst: isNewQuery, generation: gen)
        })
        await fetchService.awaitActiveFetch()
    }

    /// Search local FTS5 index and return Email results.
    private nonisolated static func localSearch(query: String, db: MailDatabase) async -> [Email] {
        do {
            return try await db.dbPool.read { database in
                let records = try FTSManager.search(query: query, in: database)
                return try records.map { record in
                    let labels = try MailDatabaseQueries.labels(forMessage: record.gmailId, in: database)
                    let tags = try EmailTagRecord
                        .filter(Column("message_id") == record.gmailId)
                        .fetchOne(database)
                    let attachments = try AttachmentRecord
                        .filter(Column("message_id") == record.gmailId)
                        .fetchAll(database)
                    return record.toEmail(labels: labels, tags: tags, attachments: attachments)
                }
            }
        } catch {
            return []
        }
    }

    func loadMore() async {
        guard nextPageToken != nil else { return }
        let gen = fetchService.currentGeneration
        await performFetch(reset: false, generation: gen)
    }

    /// Cancel any in-flight search/load task. Called from the view layer
    /// when a new search or folder navigation begins.
    func cancelActiveFetch() {
        fetchService.cancelActiveFetch()
    }

    // MARK: - Labels & Metadata

    func loadLabels() async {
        let result = await labelService.loadLabels(accountID: accountID, currentLabels: labels)
        labels = result.labels
        if let err = result.error { error = err }
    }

    func loadSendAs() async {
        let result = await labelService.loadSendAs(accountID: accountID)
        sendAsAliases = result.aliases
        if let err = result.error { error = err }
    }

    func renameLabel(_ label: GmailLabel, to newName: String) async {
        if let idx = labels.firstIndex(where: { $0.id == label.id }) {
            let updated = GmailLabel(id: label.id, name: newName, type: label.type,
                                      messagesTotal: label.messagesTotal, messagesUnread: label.messagesUnread,
                                      threadsTotal: label.threadsTotal, threadsUnread: label.threadsUnread,
                                      color: label.color)
            labels[idx] = updated
        }
        do {
            let fresh = try await GmailLabelService.shared.updateLabel(id: label.id, newName: newName, accountID: accountID)
            if let idx = labels.firstIndex(where: { $0.id == fresh.id }) { labels[idx] = fresh }
        } catch {
            if let idx = labels.firstIndex(where: { $0.id == label.id }) { labels[idx] = label }
            self.error = error.localizedDescription
        }
    }

    func deleteLabel(_ label: GmailLabel) async {
        let backup = labels
        labels.removeAll { $0.id == label.id }
        do {
            try await GmailLabelService.shared.deleteLabel(id: label.id, accountID: accountID)
        } catch {
            labels = backup
            self.error = error.localizedDescription
        }
    }

    func loadCategoryUnreadCounts() async {
        // DB fast path: compute counts locally
        if let db = mailDatabase {
            do {
                let counts = try await db.dbPool.read { database in
                    var result: [InboxCategory: Int] = [:]
                    for category in InboxCategory.allCases where category != .all {
                        // Category unread = messages with both INBOX and category label that are unread
                        let count = try Int.fetchOne(database, sql: """
                            SELECT COUNT(*) FROM messages m
                            JOIN message_labels ml1 ON ml1.message_id = m.gmail_id AND ml1.label_id = 'INBOX'
                            JOIN message_labels ml2 ON ml2.message_id = m.gmail_id AND ml2.label_id = ?
                            WHERE m.is_read = 0
                        """, arguments: [category.rawValue]) ?? 0
                        result[category] = count
                    }
                    // "All" category = total INBOX unread
                    result[.all] = try MailDatabaseQueries.unreadCount(forLabel: "INBOX", in: database)
                    return result
                }
                categoryUnreadCounts = counts
                return
            } catch {
                // Fall through to API
            }
        }
        categoryUnreadCounts = await labelService.loadCategoryUnreadCounts(accountID: accountID)
    }

    // MARK: - Account switching

    func switchAccount(_ id: String) async {
        messageObservation?.cancel()
        messageObservation = nil
        cancelActiveFetch()
        accountID              = id
        fetchService.accountID = id
        nextPageToken = nil
        readIDs       = []
        error         = nil
        fetchService.resetState()
        messages = []
    }

    // MARK: - Delta Sync via History API

    /// Refreshes the current folder using delta sync when possible,
    /// falling back to full re-fetch.
    func refreshCurrentFolder(labelIDs: [String], query: String? = nil) async {
        let isSameFolder = labelIDs == currentLabelIDs && query == currentQuery

        // Only attempt delta sync if:
        // 1. Same folder (not a folder switch)
        // 2. No search query (history API doesn't support queries)
        // 3. We have cached messages (not first load)
        // 4. Single label ID or no label (history API filters by one label)
        if isSameFolder && query == nil && !messages.isEmpty && labelIDs.count <= 1 {
            let success = await applyHistorySync(labelId: labelIDs.first)
            if success { return }
        }

        // Full refresh (existing path)
        await loadFolder(labelIDs: labelIDs, query: query)
    }

    // MARK: - Mutations

    func markAsRead(_ message: GmailMessage) async {
        guard message.isUnread && !readIDs.contains(message.id) else { return }
        readIDs.insert(message.id)
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            suppressRecompute = true
            messages[idx].labelIds?.removeAll { $0 == GmailSystemLabel.unread }
            suppressRecompute = false
            fetchService.messageCache[message.id] = messages[idx]
            updateEmailInPlace(message.id) { $0.isRead = true }
        }
        try? await api.markAsRead(id: message.id, accountID: accountID)
    }

    /// Updates local state for messages already marked as read by another component (e.g. EmailDetailVM).
    func applyReadLocally(_ messageIDs: [String]) {
        suppressRecompute = true
        for id in messageIDs {
            readIDs.insert(id)
            if let idx = messages.firstIndex(where: { $0.id == id }) {
                messages[idx].labelIds?.removeAll { $0 == GmailSystemLabel.unread }
                fetchService.messageCache[id] = messages[idx]
            }
        }
        suppressRecompute = false
        // In-place update instead of full list rebuild — only the read flag changed
        for id in messageIDs {
            updateEmailInPlace(id) { $0.isRead = true }
        }
    }

    func markAsUnread(_ messageID: String) async {
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            suppressRecompute = true
            if messages[idx].labelIds?.contains(GmailSystemLabel.unread) == false {
                messages[idx].labelIds?.append(GmailSystemLabel.unread)
            }
            suppressRecompute = false
            fetchService.messageCache[messageID] = messages[idx]
            updateEmailInPlace(messageID) { $0.isRead = false }
        }
        readIDs.remove(messageID)
        do {
            try await api.markAsUnread(id: messageID, accountID: accountID)
        } catch { self.error = error.localizedDescription }
    }

    func toggleStar(_ messageID: String, isStarred: Bool) async {
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            suppressRecompute = true
            if isStarred {
                messages[idx].labelIds?.removeAll { $0 == GmailSystemLabel.starred }
            } else {
                messages[idx].labelIds?.append(GmailSystemLabel.starred)
            }
            suppressRecompute = false
            fetchService.messageCache[messageID] = messages[idx]
            updateEmailInPlace(messageID) { $0.isStarred = !isStarred }
        }
        do {
            try await api.setStarred(!isStarred, id: messageID, accountID: accountID)
        } catch {
            // Revert on failure
            if let idx = messages.firstIndex(where: { $0.id == messageID }) {
                suppressRecompute = true
                if isStarred {
                    messages[idx].labelIds?.append(GmailSystemLabel.starred)
                } else {
                    messages[idx].labelIds?.removeAll { $0 == GmailSystemLabel.starred }
                }
                suppressRecompute = false
                fetchService.messageCache[messageID] = messages[idx]
                updateEmailInPlace(messageID) { $0.isStarred = isStarred }
            }
            self.error = error.localizedDescription
        }
    }

    func trash(_ messageID: String) async {
        do {
            let updated = try await api.trashMessage(id: messageID, accountID: accountID)
            reconcileLabelsInDatabase(messageID, serverLabelIds: updated.labelIds ?? [])
            removeFromLocalState(messageID)
        } catch { self.error = error.localizedDescription }
    }

    func archive(_ messageID: String) async {
        do {
            try await api.archiveMessage(id: messageID, accountID: accountID)
            removeFromLocalState(messageID)
        } catch { self.error = error.localizedDescription }
    }

    /// Removes a message from the in-memory list immediately (optimistic UI).
    /// Returns the removed message so it can be put back if the action is undone.
    @discardableResult
    func removeOptimistically(_ messageID: String) -> GmailMessage? {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        let msg = messages[idx]
        _ = withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            messages.remove(at: idx)
        }
        return msg
    }

    /// Re-inserts a previously removed message at its original date position (undo path).
    func restoreOptimistically(_ message: GmailMessage) {
        fetchService.messageCache[message.id] = message
        let date = message.date ?? .distantPast
        let insertIdx = messages.firstIndex { ($0.date ?? .distantPast) < date } ?? messages.endIndex
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            messages.insert(message, at: insertIdx)
        }
        lastRestoredMessageID = message.id
    }

    /// Optimistically updates labels in the database so ValueObservation reflects the change.
    /// Returns the original label IDs for undo.
    @discardableResult
    func updateLabelsInDatabase(_ messageID: String, addLabelIds: [String], removeLabelIds: [String]) -> [String]? {
        guard let db = mailDatabase else { return nil }
        do {
            return try db.dbPool.write { database in
                // Read current labels for undo
                let currentLabels = try String.fetchAll(database, sql:
                    "SELECT label_id FROM message_labels WHERE message_id = ?",
                    arguments: [messageID]
                )

                // Remove specified labels
                if !removeLabelIds.isEmpty {
                    let placeholders = removeLabelIds.map { _ in "?" }.joined(separator: ",")
                    try database.execute(
                        sql: "DELETE FROM message_labels WHERE message_id = ? AND label_id IN (\(placeholders))",
                        arguments: StatementArguments([messageID] + removeLabelIds)
                    )
                }

                // Add specified labels (ignore if already present from concurrent sync)
                for labelId in addLabelIds {
                    try LabelRecord(gmailId: labelId, name: labelId, type: nil, bgColor: nil, textColor: nil).upsert(database)
                    try MessageLabelRecord(messageId: messageID, labelId: labelId).insert(database, onConflict: .ignore)
                }

                return currentLabels
            }
        } catch {
            Self.logger.error("Optimistic DB label update failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Removes all labels from a message in the database. Returns the original labels for undo.
    func removeAllLabelsInDatabase(_ messageID: String) -> [String]? {
        guard let db = mailDatabase else { return nil }
        do {
            return try db.dbPool.write { database in
                let currentLabels = try String.fetchAll(database, sql:
                    "SELECT label_id FROM message_labels WHERE message_id = ?",
                    arguments: [messageID]
                )
                try database.execute(
                    sql: "DELETE FROM message_labels WHERE message_id = ?",
                    arguments: [messageID]
                )
                return currentLabels
            }
        } catch {
            Self.logger.error("Optimistic DB label removal failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Restores the original labels in the database (undo path).
    func restoreLabelsInDatabase(_ messageID: String, originalLabelIds: [String]) {
        guard let db = mailDatabase else { return }
        do {
            try db.dbPool.write { database in
                try database.execute(
                    sql: "DELETE FROM message_labels WHERE message_id = ?",
                    arguments: [messageID]
                )
                for labelId in originalLabelIds {
                    try MessageLabelRecord(messageId: messageID, labelId: labelId).insert(database, onConflict: .ignore)
                }
            }
        } catch {
            Self.logger.error("Label restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reconciles DB labels with the server's authoritative label set after an API mutation.
    /// Corrects any drift between our optimistic update and what the server actually applied.
    private func reconcileLabelsInDatabase(_ messageID: String, serverLabelIds: [String]) {
        guard let db = mailDatabase else { return }
        do {
            try db.dbPool.write { database in
                try database.execute(
                    sql: "DELETE FROM message_labels WHERE message_id = ?",
                    arguments: [messageID]
                )
                for labelId in serverLabelIds {
                    try LabelRecord(gmailId: labelId, name: labelId, type: nil, bgColor: nil, textColor: nil).upsert(database)
                    try MessageLabelRecord(messageId: messageID, labelId: labelId).insert(database, onConflict: .ignore)
                }
            }
        } catch {
            Self.logger.error("Label reconciliation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func emptyTrash() async {
        await emptyFolder { [api, accountID] in try await api.emptyTrash(accountID: accountID) }
    }

    func emptySpam() async {
        await emptyFolder { [api, accountID] in try await api.emptySpam(accountID: accountID) }
    }

    private func emptyFolder(action: @Sendable () async throws -> Void) async {
        let backup = messages
        let cacheBackup = fetchService.messageCache
        messages.removeAll()
        fetchService.messageCache.removeAll()
        do {
            try await action()
        } catch GmailAPIError.partialFailure {
            self.error = "Some messages could not be deleted"
        } catch {
            messages = backup
            fetchService.messageCache = cacheBackup
            self.error = error.localizedDescription
        }
    }

    func moveToInbox(_ messageID: String) async {
        do {
            try await api.modifyLabels(
                id: messageID, add: [GmailSystemLabel.inbox], remove: [], accountID: accountID
            )
            removeFromLocalState(messageID)
        } catch { self.error = error.localizedDescription }
    }

    func untrash(_ messageID: String) async {
        do {
            let updated = try await api.untrashMessage(id: messageID, accountID: accountID)
            reconcileLabelsInDatabase(messageID, serverLabelIds: updated.labelIds ?? [])
            removeFromLocalState(messageID)
        } catch { self.error = error.localizedDescription }
    }

    func deletePermanently(_ messageID: String) async {
        do {
            try await api.deleteMessagePermanently(id: messageID, accountID: accountID)
            removeFromLocalState(messageID)
        } catch { self.error = error.localizedDescription }
    }

    func unspam(_ messageID: String) async {
        do {
            try await api.modifyLabels(
                id: messageID, add: [GmailSystemLabel.inbox], remove: [GmailSystemLabel.spam], accountID: accountID
            )
            removeFromLocalState(messageID)
        } catch { self.error = error.localizedDescription }
    }

    func spam(_ messageID: String) async {
        do {
            try await api.spamMessage(id: messageID, accountID: accountID)
            removeFromLocalState(messageID)
        } catch { self.error = error.localizedDescription }
    }

    func addLabel(_ labelID: String, to messageID: String) async {
        do {
            let updated = try await api.modifyLabels(
                id: messageID, add: [labelID], remove: [], accountID: accountID
            )
            if let idx = messages.firstIndex(where: { $0.id == messageID }) {
                messages[idx].labelIds = updated.labelIds
                fetchService.messageCache[messageID] = messages[idx]
            }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func createAndAddLabel(name: String, to messageID: String) async -> String? {
        do {
            let newLabel = try await GmailLabelService.shared.createLabel(name: name, accountID: accountID)
            labels.append(newLabel)
            await addLabel(newLabel.id, to: messageID)
            // labels is @Observable-tracked — changing it triggers didSet → recomputeEmails()
            return newLabel.id
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func removeLabel(_ labelID: String, from messageID: String) async {
        do {
            let updated = try await api.modifyLabels(
                id: messageID, add: [], remove: [labelID], accountID: accountID
            )
            if let idx = messages.firstIndex(where: { $0.id == messageID }) {
                messages[idx].labelIds = updated.labelIds
                fetchService.messageCache[messageID] = messages[idx]
            }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: - GmailMessage → Email conversion

    func makeEmail(from message: GmailMessage) -> Email {
        let msgLabelIDs = message.labelIds ?? []
        let userLabels = labels.filter { !$0.isSystemLabel && msgLabelIDs.contains($0.id) }
        let emailLabels = userLabels.map { label in
            EmailLabel(
                id:    GmailDataTransformer.deterministicUUID(from: label.id),
                name:  label.displayName,
                color: label.resolvedBgColor,
                textColor: label.resolvedTextColor
            )
        }
        return Email(
            id:             GmailDataTransformer.deterministicUUID(from: message.id),
            sender:         GmailDataTransformer.parseContact(message.from),
            recipients:     GmailDataTransformer.parseContacts(message.to),
            cc:             GmailDataTransformer.parseContacts(message.cc),
            subject:        message.subject,
            body:           message.body,
            preview:        message.snippet ?? "",
            date:           message.date ?? Date(),
            isRead:         !message.isUnread,
            isStarred:      message.isStarred,
            hasAttachments: !message.attachmentParts.isEmpty,
            attachments:    message.attachmentParts.map { GmailDataTransformer.makeAttachment(from: $0, messageId: message.id) },
            folder:         GmailDataTransformer.folderFor(labelIDs: msgLabelIDs),
            labels:         emailLabels,
            isDraft:             message.isDraft,
            gmailMessageID:      message.id,
            gmailThreadID:       message.threadId,
            gmailLabelIDs:       msgLabelIDs,
            isFromMailingList:   message.isFromMailingList,
            unsubscribeURL:      message.unsubscribeURL
        )
    }

    // MARK: - Private fetch orchestration

    private func performFetch(reset: Bool, clearFirst: Bool = false, generation: UInt64) async {
        guard !accountID.isEmpty else { return }

        if reset && clearFirst {
            messages = []
        }

        isLoading = true
        error     = nil
        syncProgressManager?.syncStarted()
        defer { isLoading = false }

        do {
            // API sync: fetch latest message list
            let list = try await fetchService.listMessages(
                accountID: accountID,
                currentLabelIDs: currentLabelIDs,
                currentQuery: currentQuery,
                pageToken: reset ? nil : nextPageToken
            )
            guard !fetchService.isStale(generation: generation) else { return }

            if let estimate = list.resultSizeEstimate {
                syncProgressManager?.syncProgress(remaining: estimate)
            }

            let refs = list.messages ?? []
            nextPageToken = list.nextPageToken

            // Fetch missing messages from API
            let fetched = try await fetchService.fetchMissingMessages(refs: refs, accountID: accountID)
            guard !fetchService.isStale(generation: generation) else { return }

            let resolved = fetchService.resolveFromCache(refs)

            // Write to DB via BackgroundSyncer (ValueObservation will update UI)
            if let syncer = backgroundSyncer, !resolved.isEmpty {
                let labelIds = Array(Set(resolved.flatMap { $0.labelIds ?? [] }))
                try? await syncer.upsertMessages(resolved, ensureLabels: labelIds)
            }

            let fetchedCount = resolved.count
            if let estimate = list.resultSizeEstimate, estimate > fetchedCount {
                syncProgressManager?.syncProgress(remaining: estimate - fetchedCount)
            }

            // Background analysis (subscriptions, attachments, AI classification)
            if !fetched.isEmpty {
                fetchService.analyzeInBackground(fetched)
            }

            // Stale pruning: remove messages that disappeared from API
            if reset && !refs.isEmpty {
                await pruneStaleMessages(refs: refs, generation: generation)
            }

            // Update history ID for delta sync
            if reset, let latestHistoryId = resolved.compactMap(\.historyId).first {
                historyService.updateStoredHistoryId(latestHistoryId, accountID: accountID)
            }

            syncProgressManager?.syncCompleted()
        } catch is CancellationError {
            // Silently swallow
        } catch {
            guard !fetchService.isStale(generation: generation) else { return }
            self.error = error.localizedDescription
            syncProgressManager?.syncFailed()
        }
    }

    private func pruneStaleMessages(refs: [GmailMessageRef], generation: UInt64) async {
        let serverIDs = Set(refs.map(\.id))
        // Use messages currently in the list as suspects
        let suspectIDs = messages.filter { !serverIDs.contains($0.id) }.map(\.id)
        guard !suspectIDs.isEmpty else { return }
        guard !fetchService.isStale(generation: generation) else { return }

        let verified = await fetchService.verifyMessages(ids: suspectIDs, accountID: accountID, api: api)
        var staleIDs: [String] = []
        let folderLabels = Set(currentLabelIDs)
        for id in suspectIDs {
            if let msg = verified[id] {
                if !folderLabels.isEmpty,
                   let msgLabels = msg.labelIds,
                   folderLabels.isDisjoint(with: Set(msgLabels)) {
                    staleIDs.append(id)
                }
            } else {
                staleIDs.append(id)
            }
        }
        if !staleIDs.isEmpty {
            if let syncer = backgroundSyncer {
                try? await syncer.deleteMessages(gmailIds: staleIDs)
            }
            for id in staleIDs { fetchService.messageCache[id] = nil }
        }
    }

    /// Applies the result of a history sync to the VM's observable state.
    private func applyHistorySync(labelId: String?) async -> Bool {
        syncProgressManager?.syncStarted()
        let existingIDs = Set(messages.map(\.id))
        let result = await historyService.syncViaHistory(
            accountID: accountID,
            labelId: labelId,
            existingMessageIDs: existingIDs
        )
        guard result.succeeded else {
            syncProgressManager?.syncFailed()
            return false
        }

        // Write delta to DB (ValueObservation will update UI)
        if let syncer = backgroundSyncer {
            var labelUpdates: [(gmailId: String, labelIds: [String])] = []
            for msg in result.refreshedMessages {
                labelUpdates.append((gmailId: msg.id, labelIds: msg.labelIds ?? []))
            }
            try? await syncer.applyDelta(
                newMessages: result.newMessages,
                deletedIds: Array(result.deletedIDs),
                labelUpdates: labelUpdates
            )
        }

        // Update in-memory state for immediate responsiveness.
        // Suppress recompute during the batch — call once at the end.
        suppressRecompute = true
        if !result.deletedIDs.isEmpty {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                messages.removeAll { result.deletedIDs.contains($0.id) }
            }
            for id in result.deletedIDs { fetchService.messageCache[id] = nil }
        }

        if !result.newMessages.isEmpty {
            for msg in result.newMessages { fetchService.messageCache[msg.id] = msg }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                messages.insert(contentsOf: result.newMessages, at: 0)
            }
            fetchService.analyzeInBackground(result.newMessages)
        }

        for msg in result.refreshedMessages {
            fetchService.messageCache[msg.id] = msg
            if let labelId, let msgLabels = msg.labelIds, !msgLabels.contains(labelId) {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    messages.removeAll { $0.id == msg.id }
                }
                fetchService.messageCache[msg.id] = nil
            } else {
                if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                    messages[idx] = msg
                }
            }
        }
        suppressRecompute = false
        recomputeEmails()

        if let historyId = result.latestHistoryId {
            historyService.updateStoredHistoryId(historyId, accountID: accountID)
        }

        if let err = result.error { error = err }
        syncProgressManager?.syncCompleted()
        return true
    }

    private func removeFromLocalState(_ messageID: String) {
        messages.removeAll { $0.id == messageID }
        fetchService.messageCache[messageID] = nil
    }

    private func updateEmailInPlace(_ messageID: String, update: (inout Email) -> Void) {
        if let idx = emails.firstIndex(where: { $0.gmailMessageID == messageID }) {
            update(&emails[idx])
        }
    }
}
