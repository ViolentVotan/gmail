private import GRDB
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
///
/// DB-only architecture: folder loads start a `ValueObservation` on the label;
/// the sync engine populates the database, and observation drives the UI.
@Observable
@MainActor
final class MailboxViewModel {
    var isLoading      = false
    var labels:        [GmailLabel] = []
    private(set) var userLabels: [GmailLabel] = []
    var sendAsAliases:         [GmailSendAs] = []
    var categoryUnreadCounts:  [InboxCategory: Int] = [:]
    var folderUnreadCounts:    [Folder: Int] = [:]
    private(set) var emails: [Email] = [] {
        didSet { onEmailsChanged?() }
    }

    /// Called by the coordinator to stay notified when `emails` changes
    /// (e.g. from ValueObservation or search results).
    @ObservationIgnored var onEmailsChanged: (() -> Void)?

    var priorityFilterEnabled: Bool = false
    @ObservationIgnored private var displayLimit: Int = 200
    private(set) var hasMoreEmails: Bool = false
    private(set) var isLoadingMore: Bool = false

    var accountID: String
    @ObservationIgnored private var currentLabelIDs: [String] = [GmailSystemLabel.inbox]
    @ObservationIgnored private var currentQuery:    String?

    // MARK: - Services

    /// Database label mutations and API mutation proxying. Callers that need to modify
    /// email labels or perform optimistic actions should go through this service.
    let labelMutations: LabelMutationService

    @ObservationIgnored private(set) var mailDatabase: MailDatabase?
    @ObservationIgnored private(set) var backgroundSyncer: BackgroundSyncer?

    func setMailDatabase(_ db: MailDatabase?) {
        self.mailDatabase = db
        labelMutations.setMailDatabase(db)
    }

    func setBackgroundSyncer(_ syncer: BackgroundSyncer?) {
        self.backgroundSyncer = syncer
        labelMutations.setBackgroundSyncer(syncer)
    }

    @ObservationIgnored private(set) var syncProgressManager: SyncProgressManager?

    func setSyncProgressManager(_ manager: SyncProgressManager) {
        self.syncProgressManager = manager
    }

    nonisolated private static let logger = Logger(category: "Mailbox")
    private let api: MessageFetching
    private let labelService: LabelSyncService
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var enrichmentTask: Task<Void, Never>?
    @ObservationIgnored private var observationDebounceTask: Task<Void, Never>?
    /// Fingerprint of the last processed observation result, used to skip
    /// redundant `toEmail()` conversions when the DB fires duplicate updates.
    @ObservationIgnored private var lastObservedFingerprint: Int = 0

    init(
        accountID: String,
        api: MessageFetching = GmailMessageService.shared
    ) {
        self.accountID = accountID
        self.api = api
        self.labelService = LabelSyncService.shared
        self.labelMutations = LabelMutationService(accountID: accountID, api: api)
        self.labelMutations.onUnreadCountsChanged = { [weak self] in
            await self?.loadFolderUnreadCounts()
        }
    }

    isolated deinit {
        observationTask?.cancel()
        enrichmentTask?.cancel()
        observationDebounceTask?.cancel()
    }

    // MARK: - Database Observation

    func startObservingLabels(_ labelIDs: [String]) {
        observationDebounceTask?.cancel()
        observationDebounceTask = nil
        observationTask?.cancel()
        lastObservedFingerprint = 0
        guard let db = mailDatabase, let primaryLabel = labelIDs.first else { return }
        // Use GRDB association prefetching: 4 queries instead of N+1.
        // Query 1: SELECT m.* FROM messages … (filtered by label(s))
        // Query 2: SELECT l.* FROM labels WHERE … IN (...) (batch)
        // Query 3: SELECT t.* FROM email_tags WHERE … IN (...) (batch)
        // Query 4: SELECT a.* FROM attachments WHERE … IN (...) (batch)
        let base: QueryInterfaceRequest<MessageRecord>
        if labelIDs.count == 1 {
            // Single label: efficient JOIN
            base = MessageRecord
                .joining(required: MessageRecord.messageLabels
                    .filter(Column("label_id") == primaryLabel))
        } else {
            // Multiple labels (e.g. INBOX + CATEGORY_PERSONAL): require ALL labels present.
            // Matches Gmail API semantics where labelIds filters by AND.
            let placeholders = labelIDs.sqlPlaceholders
            base = MessageRecord
                .filter(sql: """
                    gmail_id IN (
                        SELECT message_id FROM message_labels
                        WHERE label_id IN (\(placeholders))
                        GROUP BY message_id
                        HAVING COUNT(DISTINCT label_id) = \(labelIDs.count)
                    )
                """, arguments: StatementArguments(labelIDs))
        }
        let request = base
            .select(MessageRecord.listColumns)
            .including(all: MessageRecord.labels)
            .including(optional: MessageRecord.tags)
            .including(all: MessageRecord.attachments)
            .order(Column("internal_date").desc)
            .limit(displayLimit)
            .asRequest(of: MessageWithAssociations.self)
        // Use tracking (not trackingConstantRegion): the JOIN through
        // message_labels means the tracked region varies with the label filter,
        // so GRDB must derive it from each execution to catch all updates.
        let observation = ValueObservation.tracking { db in
            try request.fetchAll(db)
        }
        observationTask = Task { @MainActor [weak self] in
            do {
                for try await records in observation.values(in: db.dbPool) {
                    guard let self else { return }
                    // Debounce rapid batch writes: discard intermediate updates and
                    // process only the last one in a burst (50ms window).
                    self.observationDebounceTask?.cancel()
                    self.observationDebounceTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled, let self else { return }
                        self.handleDatabaseUpdate(records, from: db)
                    }
                }
            } catch is CancellationError {
                // Normal task cancellation (e.g. folder/account switch) — not an error
            } catch {
                self?.isLoading = false
                ToastManager.shared.show(message: "Database observation failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    private func handleDatabaseUpdate(_ records: [MessageWithAssociations], from db: MailDatabase) {
        // Stale check: ignore updates from a previous account's database
        guard db === mailDatabase else { return }

        // Skip redundant conversions: compute a lightweight fingerprint from
        // message IDs and key mutable columns to detect whether anything
        // actually changed since the last observation result.
        let fingerprint = Self.computeFingerprint(records)
        guard fingerprint != lastObservedFingerprint else { return }
        lastObservedFingerprint = fingerprint

        let fetchedCount = records.count
        let limit = displayLimit
        enrichmentTask?.cancel()
        enrichmentTask = Task { [weak self] in
            let threadEmails = await Task.detached {
                Self.threadedEmails(from: records)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, db === self.mailDatabase else { return }
                // Guard against empty results when the observation returned non-empty records
                if threadEmails.isEmpty && !records.isEmpty { return }
                // Only show "load more" if the DB query hit the limit (more raw rows may exist)
                // AND we haven't already loaded all available messages
                self.hasMoreEmails = fetchedCount >= limit
                self.isLoadingMore = false
                self.isLoading = false
                self.emails = threadEmails
            }
        }
    }

    /// Lightweight fingerprint from record IDs and key mutable columns.
    /// Used to skip the expensive `toEmail()` conversion when the DB fires
    /// duplicate observation updates during bulk sync writes.
    nonisolated private static func computeFingerprint(_ records: [MessageWithAssociations]) -> Int {
        var hasher = Hasher()
        hasher.combine(records.count)
        for row in records {
            hasher.combine(row.message.gmailId)
            hasher.combine(row.message.historyId)
            hasher.combine(row.message.isRead)
            hasher.combine(row.message.isStarred)
            for label in row.labels {
                hasher.combine(label.gmailId)
            }
        }
        return hasher.finalize()
    }

    /// Convert association-prefetched records into threaded Email models.
    /// Pure computation — no database access needed.
    nonisolated private static func threadedEmails(from records: [MessageWithAssociations]) -> [Email] {
        let emails = records.map { row in
            row.message.toEmail(labels: row.labels, tags: row.tags, attachments: row.attachments)
        }
        let grouped = Dictionary(grouping: emails) { $0.gmailThreadID ?? $0.gmailMessageID ?? $0.id.uuidString }
        var result: [Email] = []
        result.reserveCapacity(grouped.count)
        for (_, threadEmails) in grouped {
            guard var latest = threadEmails.max(by: { $0.date < $1.date }) else { continue }
            let maxThreadCount = threadEmails.map(\.threadMessageCount).max() ?? 0
            latest.threadMessageCount = max(maxThreadCount, threadEmails.count)
            result.append(latest)
        }
        result.sort { $0.date > $1.date }
        return result
    }

    // MARK: - Load

    /// Loads a folder by starting a DB observation on the label.
    /// Search queries are handled via FTS + API.
    func loadFolder(labelIDs: [String], query: String? = nil) async {
        currentLabelIDs = labelIDs
        currentQuery = query
        displayLimit = 200

        if let query, !query.isEmpty {
            // Search still uses FTS for local, API for server-side
            await search(query: query)
            return
        }

        // DB-only path: start observing the label(s)
        if !labelIDs.isEmpty, mailDatabase != nil {
            if emails.isEmpty { isLoading = true }
            startObservingLabels(labelIDs)
        }
    }

    /// Cancels any in-flight fetch and starts a new search.
    func search(query: String) async {
        observationDebounceTask?.cancel()
        let newQuery = query.isEmpty ? nil : query
        currentQuery = newQuery

        // FTS fast path: search local database first for instant results
        if let q = newQuery, let db = mailDatabase {
            observationTask?.cancel()
            observationTask = nil
            let localResults = await Self.localSearch(query: q, db: db)
            if !localResults.isEmpty {
                emails = localResults
            }
        }

        // TODO: Task 11 — add server-side search fallback for queries with no local results
    }

    /// Search local FTS5 index and return Email results.
    /// Uses association prefetching (4 queries total) instead of N+1 per result.
    private nonisolated static func localSearch(query: String, db: MailDatabase) async -> [Email] {
        do {
            return try await db.dbPool.read { database in
                // FTS5 match to get gmail_ids
                guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }

                // Use association prefetching: 1 query for messages + 3 batch queries for associations
                let request = MessageRecord
                    .select(MessageRecord.listColumns)
                    .filter(sql: """
                        gmail_id IN (
                            SELECT gmail_id FROM messages_fts WHERE messages_fts MATCH ?
                        )
                    """, arguments: [pattern])
                    .including(all: MessageRecord.labels)
                    .including(optional: MessageRecord.tags)
                    .including(all: MessageRecord.attachments)
                    .order(Column("internal_date").desc)
                    .limit(100)
                    .asRequest(of: MessageWithAssociations.self)

                let rows = try request.fetchAll(database)
                return rows.map { row in
                    row.message.toEmail(labels: row.labels, tags: row.tags, attachments: row.attachments)
                }
            }
        } catch {
            return []
        }
    }

    /// Refreshes the current folder. If the label/query changed, starts a new observation.
    /// Otherwise the sync engine handles incremental sync and ValueObservation updates UI.
    func refreshCurrentFolder(labelIDs: [String], query: String? = nil) async {
        if labelIDs != currentLabelIDs || query != currentQuery || observationTask == nil {
            await loadFolder(labelIDs: labelIDs, query: query)
        }
        // Otherwise: sync engine handles incremental sync, ValueObservation updates UI
    }

    /// Expands the observation limit to load more emails (infinite scroll).
    func loadMore() {
        guard hasMoreEmails, !isLoadingMore else { return }
        if let q = currentQuery, !q.isEmpty { return }
        isLoadingMore = true
        displayLimit += 200
        startObservingLabels(currentLabelIDs)
    }

    // MARK: - Labels & Metadata

    func loadLabels() async {
        let result = await labelService.loadLabels(accountID: accountID, currentLabels: labels)
        labels = result.labels
        userLabels = labels.filter { !$0.isSystemLabel }
        if result.error != nil {
            ToastManager.shared.show(message: "Failed to load labels", type: .error)
        }
    }

    func loadSendAs() async {
        let result = await labelService.loadSendAs(accountID: accountID)
        sendAsAliases = result.aliases
        if result.error != nil {
            ToastManager.shared.show(message: "Failed to load send-as aliases", type: .error)
        }
    }

    /// Appends a new label and recomputes the user labels list.
    /// Used by `LabelMutationService.createAndAddLabel` via its `appendLabel` callback.
    func appendLabel(_ label: GmailLabel) {
        labels.append(label)
        recomputeUserLabels()
    }

    private func recomputeUserLabels() {
        userLabels = labels.filter { !$0.isSystemLabel }
    }

    func renameLabel(_ label: GmailLabel, to newName: String) async {
        if let idx = labels.firstIndex(where: { $0.id == label.id }) {
            let updated = GmailLabel(id: label.id, name: newName, type: label.type,
                                      messagesTotal: label.messagesTotal, messagesUnread: label.messagesUnread,
                                      color: label.color,
                                      labelListVisibility: label.labelListVisibility,
                                      messageListVisibility: label.messageListVisibility)
            labels[idx] = updated
        }
        do {
            let fresh = try await GmailLabelService.shared.updateLabel(id: label.id, newName: newName, accountID: accountID)
            if let idx = labels.firstIndex(where: { $0.id == fresh.id }) {
                labels[idx] = fresh
            }
        } catch {
            if let idx = labels.firstIndex(where: { $0.id == label.id }) {
                labels[idx] = label
            }
            ToastManager.shared.show(message: "Failed to rename label", type: .error)
        }
        recomputeUserLabels()
    }

    func deleteLabel(_ label: GmailLabel) async {
        let backup = labels
        labels.removeAll { $0.id == label.id }
        do {
            try await GmailLabelService.shared.deleteLabel(id: label.id, accountID: accountID)
            _ = try? await mailDatabase?.dbPool.write { db in
                try LabelRecord.filter(Column("gmail_id") == label.id).deleteAll(db)
            }
        } catch {
            labels = backup
            ToastManager.shared.show(message: "Failed to delete label", type: .error)
        }
        recomputeUserLabels()
    }

    func loadCategoryUnreadCounts() async {
        if let db = mailDatabase {
            do {
                let counts = try await db.dbPool.read { database in
                    var result: [InboxCategory: Int] = [:]
                    let categoryIds = InboxCategory.allCases
                        .filter { $0 != .all }
                        .map { $0.rawValue }
                    let placeholders = categoryIds.sqlPlaceholders
                    let rows = try Row.fetchAll(database, sql: """
                        SELECT ml2.label_id, COUNT(*) AS cnt FROM messages m
                        JOIN message_labels ml1 ON ml1.message_id = m.gmail_id AND ml1.label_id = ?
                        JOIN message_labels ml2 ON ml2.message_id = m.gmail_id
                        WHERE m.is_read = 0 AND ml2.label_id IN (\(placeholders))
                        GROUP BY ml2.label_id
                    """, arguments: StatementArguments([GmailSystemLabel.inbox] + categoryIds))
                    for row in rows {
                        let labelId: String = row["label_id"]
                        let count: Int = row["cnt"]
                        if let cat = InboxCategory.allCases.first(where: { $0.rawValue == labelId }) {
                            result[cat] = count
                        }
                    }
                    result[.all] = try MailDatabaseQueries.unreadCount(forLabel: GmailSystemLabel.inbox, in: database)
                    return result
                }
                categoryUnreadCounts = counts
                await loadFolderUnreadCounts()
                await Self.updateDockBadge()
                return
            } catch {
                // Fall through to API
            }
        }
        if let counts = await labelService.loadCategoryUnreadCounts(accountID: accountID) {
            categoryUnreadCounts = counts
        }
        await Self.updateDockBadge()
        await loadFolderUnreadCounts()
    }

    /// Loads unread counts for sidebar folders that have a Gmail label ID.
    func loadFolderUnreadCounts() async {
        guard let db = mailDatabase else { return }
        do {
            let counts = try await db.dbPool.read { database in
                let folderLabelPairs: [(Folder, String)] = Folder.mainFolders.compactMap { folder in
                    guard let labelId = folder.gmailLabelID else { return nil }
                    return (folder, labelId)
                }
                guard !folderLabelPairs.isEmpty else { return [Folder: Int]() }
                let labelIds = folderLabelPairs.map(\.1)
                let placeholders = labelIds.sqlPlaceholders
                let rows = try Row.fetchAll(database, sql: """
                    SELECT ml.label_id, COUNT(*) AS cnt FROM messages m
                    JOIN message_labels ml ON ml.message_id = m.gmail_id
                    WHERE m.is_read = 0 AND ml.label_id IN (\(placeholders))
                    GROUP BY ml.label_id
                """, arguments: StatementArguments(labelIds))
                var result: [Folder: Int] = [:]
                for row in rows {
                    let labelId: String = row["label_id"]
                    let count: Int = row["cnt"]
                    if let folder = folderLabelPairs.first(where: { $0.1 == labelId })?.0 {
                        result[folder] = count
                    }
                }
                return result
            }
            folderUnreadCounts = counts
        } catch {
            // Non-critical — keep stale counts rather than clearing
        }
    }

    /// Sums inbox unread counts across all accounts and updates the dock badge.
    static func updateDockBadge() async {
        await NotificationService.updateDockBadge()
    }

    // MARK: - Account switching

    func switchAccount(_ id: String) async {
        observationTask?.cancel()
        observationTask = nil
        enrichmentTask?.cancel()
        enrichmentTask = nil
        observationDebounceTask?.cancel()
        observationDebounceTask = nil
        lastObservedFingerprint = 0
        accountID = id
        labelMutations.accountID = id
        emails    = []
        displayLimit = 200
        hasMoreEmails = false
        isLoadingMore = false
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
        return GmailDataTransformer.makeEmail(from: message, labels: emailLabels)
    }

}
