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

/// Per-message label mutation logic: reads current labels, applies a transform, writes results,
/// and syncs denormalized `is_read`/`is_starred` columns via `MailDatabaseQueries.rebuildLabels`.
/// Called inside an existing write transaction — does **not** open one itself.
/// Returns the **original** label IDs (before the transform) for undo.
///
/// File-scope to avoid `@MainActor` isolation inheritance from `MailboxViewModel`.
private func mutateLabels(
    for messageID: String,
    in database: Database,
    transform: (inout Set<String>) -> Void
) throws -> [String] {
    // 1. Read current labels
    let currentLabels = try String.fetchAll(database, sql:
        "SELECT label_id FROM message_labels WHERE message_id = ?",
        arguments: [messageID]
    )
    var labels = Set(currentLabels)

    // 2. Apply transform
    transform(&labels)

    // 3. Rebuild labels + sync denormalized columns via shared helper
    try MailDatabaseQueries.rebuildLabels(
        forMessageID: messageID,
        newLabelIDs: Array(labels),
        in: database
    )

    return currentLabels
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
    /// Set by `restoreLabelsInDatabase` so the UI can re-select the restored email.
    var lastRestoredMessageID: String?
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

    @ObservationIgnored private(set) var mailDatabase: MailDatabase?
    @ObservationIgnored private(set) var backgroundSyncer: BackgroundSyncer?

    func setMailDatabase(_ db: MailDatabase?) {
        self.mailDatabase = db
    }

    func setBackgroundSyncer(_ syncer: BackgroundSyncer?) {
        self.backgroundSyncer = syncer
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
                ToastManager.shared.show(message: "Database observation failed", type: .error)
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
            hasher.combine(row.labels.count)
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
            startObservingLabels(labelIDs)
        }
    }

    /// Cancels any in-flight fetch and starts a new search.
    func search(query: String) async {
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
        emails    = []
        displayLimit = 200
        hasMoreEmails = false
        isLoadingMore = false
    }

    // MARK: - Mutations (internal — use EmailActionCoordinator for user-facing actions)

    /// Shared optimistic-update flow: write labels to DB, call API, revert on failure.
    ///
    /// 1. Applies `addLabelIDs` / `removeLabelIDs` to the message's labels in the DB.
    /// 2. Calls `apiCall` (which may also reconcile server labels on success).
    /// 3. On failure: reverts to original labels, sets `self.error`, shows a toast.
    ///
    /// - Parameters:
    ///   - messageID: The Gmail message ID.
    ///   - addLabelIDs: Labels to add optimistically.
    ///   - removeLabelIDs: Labels to remove optimistically.
    ///   - apiCall: The API operation. May perform post-success reconciliation.
    ///   - failureToast: The toast message shown on failure.
    @discardableResult
    private func performOptimisticAction(
        _ messageID: String,
        addLabelIDs: [String] = [],
        removeLabelIDs: [String] = [],
        apiCall: () async throws -> Void,
        failureToast: String
    ) async -> Bool {
        let original = await updateLabelsInDatabase(messageID, addLabelIds: addLabelIDs, removeLabelIds: removeLabelIDs)
        do {
            try await apiCall()
            return true
        } catch {
            if let original { await restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            ToastManager.shared.show(message: failureToast, type: .error)
            return false
        }
    }

    /// Marks a message as read. Optimistic DB write → API call → revert on failure.
    /// - Note: Called by `SelectionCoordinator` (auto-mark-read) and `EmailActionCoordinator`.
    ///   Views should use `EmailActionCoordinator.markReadEmail(_:)` for user-initiated actions.
    func markAsRead(_ messageID: String) async {
        await performOptimisticAction(
            messageID,
            removeLabelIDs: [GmailSystemLabel.unread],
            apiCall: { [api, accountID] in
                try await api.markAsRead(id: messageID, accountID: accountID)
            },
            failureToast: "Failed to mark as read"
        )
    }

    /// Updates DB read state for messages already marked as read by another component (e.g. EmailDetailVM).
    /// Batches all updates in a single write transaction to avoid N separate ValueObservation notifications.
    func applyReadLocally(_ messageIDs: [String]) async {
        guard let db = mailDatabase, !messageIDs.isEmpty else { return }
        do {
            try await db.dbPool.write { database in
                for id in messageIDs {
                    try mutateLabels(for: id, in: database) { labels in
                        labels.remove(GmailSystemLabel.unread)
                    }
                }
            }
        } catch {
            Self.logger.error("Batch applyReadLocally failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Marks a message as unread. Optimistic DB write → API call → revert on failure.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.markUnreadEmail(_:)`.
    func markAsUnread(_ messageID: String) async {
        await performOptimisticAction(
            messageID,
            addLabelIDs: [GmailSystemLabel.unread],
            apiCall: { [api, accountID] in
                try await api.markAsUnread(id: messageID, accountID: accountID)
            },
            failureToast: "Failed to mark as unread"
        )
    }

    /// Toggles star on a message. Optimistic DB write → API call → revert on failure.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.toggleStarEmail(_:)`.
    func toggleStar(_ messageID: String, isStarred: Bool) async {
        await performOptimisticAction(
            messageID,
            addLabelIDs: isStarred ? [] : [GmailSystemLabel.starred],
            removeLabelIDs: isStarred ? [GmailSystemLabel.starred] : [],
            apiCall: { [api, accountID] in
                try await api.setStarred(!isStarred, id: messageID, accountID: accountID)
            },
            failureToast: "Failed to toggle star"
        )
    }

    /// Trashes a message. Optimistic DB write → API call → reconcile or revert.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.deleteEmail(_:selectNext:)`.
    func trash(_ messageID: String) async {
        await performOptimisticAction(
            messageID,
            addLabelIDs: [GmailSystemLabel.trash],
            removeLabelIDs: [GmailSystemLabel.inbox],
            apiCall: { [api, accountID, weak self] in
                let updated = try await api.trashMessage(id: messageID, accountID: accountID)
                await self?.reconcileLabelsInDatabase(messageID, serverLabelIds: updated.labelIds ?? [])
            },
            failureToast: "Failed to trash message"
        )
    }

    /// Archives a message. Optimistic DB write → API call → revert on failure.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.archiveEmail(_:selectNext:)`.
    @discardableResult
    func archive(_ messageID: String) async -> Bool {
        await performOptimisticAction(
            messageID,
            removeLabelIDs: [GmailSystemLabel.inbox],
            apiCall: { [api, accountID] in
                try await api.archiveMessage(id: messageID, accountID: accountID)
            },
            failureToast: "Failed to archive"
        )
    }

    // MARK: - Label mutation helper

    /// Core label-mutation helper. Reads current labels, applies a transform, writes results,
    /// and syncs denormalized `is_read`/`is_starred` columns — all in a single write transaction.
    /// Returns the **original** label IDs (before the transform) for undo, or `nil` on failure.
    ///
    /// - Parameters:
    ///   - messageID: The Gmail message ID.
    ///   - transform: Mutates the current label set in place.
    @discardableResult
    private func writeLabels(
        _ messageID: String,
        transform: @Sendable (inout Set<String>) -> Void
    ) async -> [String]? {
        guard let db = mailDatabase else { return nil }
        do {
            return try await db.dbPool.write { database in
                try mutateLabels(
                    for: messageID,
                    in: database,
                    transform: transform
                )
            }
        } catch {
            Self.logger.error("DB label mutation failed for \(messageID, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Optimistically updates labels in the database so ValueObservation reflects the change.
    /// Returns the original label IDs for undo.
    @discardableResult
    func updateLabelsInDatabase(_ messageID: String, addLabelIds: [String], removeLabelIds: [String]) async -> [String]? {
        await writeLabels(messageID) { labels in
            labels.subtract(removeLabelIds)
            labels.formUnion(addLabelIds)
        }
    }

    /// Batch-updates labels for multiple messages in a single write transaction.
    /// Returns a map of messageID -> original label IDs for undo.
    @discardableResult
    func updateLabelsInDatabaseBatch(_ messageIDs: [String], addLabelIds: [String], removeLabelIds: [String]) async -> [String: [String]] {
        guard let db = mailDatabase else { return [:] }
        do {
            return try await db.dbPool.write { database in
                var originalLabelsMap: [String: [String]] = [:]
                for msgID in messageIDs {
                    let original = try mutateLabels(
                        for: msgID,
                        in: database
                    ) { labels in
                        labels.subtract(removeLabelIds)
                        labels.formUnion(addLabelIds)
                    }
                    originalLabelsMap[msgID] = original
                }
                return originalLabelsMap
            }
        } catch {
            Self.logger.error("Batch DB label mutation failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Removes all labels from a message in the database. Returns the original labels for undo.
    func removeAllLabelsInDatabase(_ messageID: String) async -> [String]? {
        await writeLabels(messageID) { labels in
            labels.removeAll()
        }
    }

    /// Restores the original labels in the database (undo path).
    func restoreLabelsInDatabase(_ messageID: String, originalLabelIds: [String]) async {
        await writeLabels(messageID) { labels in
            labels = Set(originalLabelIds)
        }
    }

    /// Reconciles DB labels with the server's authoritative label set after an API mutation.
    /// Corrects any drift between our optimistic update and what the server actually applied.
    private func reconcileLabelsInDatabase(_ messageID: String, serverLabelIds: [String]) async {
        await writeLabels(messageID) { labels in
            labels = Set(serverLabelIds)
        }
    }

    /// Permanently deletes all messages in Trash.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.emptyTrashFolder()`.
    func emptyTrash() async {
        await emptyFolder { [api, accountID] in try await api.emptyTrash(accountID: accountID) }
    }

    /// Permanently deletes all messages in Spam.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.emptySpamFolder()`.
    func emptySpam() async {
        await emptyFolder { [api, accountID] in try await api.emptySpam(accountID: accountID) }
    }

    private func emptyFolder(action: @Sendable () async throws -> Void) async {
        do {
            try await action()
            // Sync engine will detect changes on next delta sync; ValueObservation updates UI.
        } catch GmailAPIError.partialFailure {
            ToastManager.shared.show(message: "Some messages could not be deleted", type: .error)
        } catch {
            ToastManager.shared.show(message: "Failed to empty folder", type: .error)
        }
    }

    /// Moves a message to inbox. Optimistic DB write → API call → revert on failure.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.moveToInboxEmail(_:selectedFolder:selectNext:)`.
    func moveToInbox(_ messageID: String) async {
        await performOptimisticAction(
            messageID,
            addLabelIDs: [GmailSystemLabel.inbox],
            apiCall: { [api, accountID] in
                try await api.modifyLabels(
                    id: messageID, add: [GmailSystemLabel.inbox], remove: [], accountID: accountID
                )
            },
            failureToast: "Failed to move to inbox"
        )
    }

    /// Untrashes a message. Optimistic DB write → API call → reconcile or revert.
    /// - Note: Internal — called by `EmailActionCoordinator`.
    func untrash(_ messageID: String) async {
        await performOptimisticAction(
            messageID,
            removeLabelIDs: [GmailSystemLabel.trash],
            apiCall: { [api, accountID, weak self] in
                let updated = try await api.untrashMessage(id: messageID, accountID: accountID)
                await self?.reconcileLabelsInDatabase(messageID, serverLabelIds: updated.labelIds ?? [])
            },
            failureToast: "Failed to untrash"
        )
    }

    /// Permanently deletes a message. Removes all labels from DB optimistically,
    /// then deletes the message record itself after a successful API call.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.deletePermanentlyEmail(_:selectNext:)`.
    ///
    /// - Parameters:
    ///   - messageID: The Gmail message ID.
    ///   - originalLabelIds: When provided (e.g. from the coordinator's earlier optimistic write),
    ///     skips the redundant `removeAllLabelsInDatabase` and uses these labels for rollback.
    func deletePermanently(_ messageID: String, originalLabelIds: [String]? = nil) async {
        let original: [String]?
        if let originalLabelIds {
            original = originalLabelIds
        } else {
            original = await removeAllLabelsInDatabase(messageID)
        }
        do {
            try await api.deleteMessagePermanently(id: messageID, accountID: accountID)
            // Delete the message record (CASCADE handles message_labels, email_tags, attachments).
            // Use BackgroundSyncer when available for FTS cleanup; fall back to direct delete.
            if let syncer = backgroundSyncer {
                try? await syncer.deleteMessages(gmailIds: [messageID])
            } else {
                _ = try? await mailDatabase?.dbPool.write { db in
                    try MessageRecord.deleteOne(db, key: messageID)
                }
            }
        } catch {
            if let original { await restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            ToastManager.shared.show(message: "Failed to delete permanently", type: .error)
        }
    }

    /// Marks a message as not spam. Optimistic DB write → API call → revert on failure.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.markNotSpamEmail(_:selectNext:)`.
    func unspam(_ messageID: String) async {
        await performOptimisticAction(
            messageID,
            addLabelIDs: [GmailSystemLabel.inbox],
            removeLabelIDs: [GmailSystemLabel.spam],
            apiCall: { [api, accountID] in
                try await api.modifyLabels(
                    id: messageID, add: [GmailSystemLabel.inbox], remove: [GmailSystemLabel.spam], accountID: accountID
                )
            },
            failureToast: "Failed to remove spam"
        )
    }

    /// Marks a message as spam. Optimistic DB write → API call → revert on failure.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.markSpamEmail(_:selectNext:)`.
    func spam(_ messageID: String) async {
        await performOptimisticAction(
            messageID,
            addLabelIDs: [GmailSystemLabel.spam],
            removeLabelIDs: [GmailSystemLabel.inbox],
            apiCall: { [api, accountID] in
                try await api.spamMessage(id: messageID, accountID: accountID)
            },
            failureToast: "Failed to mark as spam"
        )
    }

    /// Adds a user label to a message. Handles optimistic DB update, offline queue, and API call.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.addLabelToEmail(_:to:)`.
    func addLabel(_ labelID: String, to messageID: String) async {
        await modifyLabel(labelID, on: messageID, isAdding: true)
    }

    /// Creates a new label and adds it to a message.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.createAndAddLabelToEmail(name:to:)`.
    @discardableResult
    func createAndAddLabel(name: String, to messageID: String) async -> String? {
        do {
            let newLabel = try await GmailLabelService.shared.createLabel(name: name, accountID: accountID)
            labels.append(newLabel)
            userLabels = labels.filter { !$0.isSystemLabel }
            await addLabel(newLabel.id, to: messageID)
            return newLabel.id
        } catch {
            ToastManager.shared.show(message: "Failed to create label", type: .error)
            return nil
        }
    }

    /// Removes a user label from a message. Handles optimistic DB update, offline queue, and API call.
    /// - Note: Internal — called by `EmailActionCoordinator`. Views should use
    ///   `EmailActionCoordinator.removeLabelFromEmail(_:from:)`.
    func removeLabel(_ labelID: String, from messageID: String) async {
        await modifyLabel(labelID, on: messageID, isAdding: false)
    }

    private func modifyLabel(_ labelID: String, on messageID: String, isAdding: Bool) async {
        let addIDs    = isAdding ? [labelID] : []
        let removeIDs = isAdding ? [] : [labelID]
        let original  = await updateLabelsInDatabase(messageID, addLabelIds: addIDs, removeLabelIds: removeIDs)
        guard NetworkMonitor.shared.isConnected else {
            await OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: isAdding ? .addLabel : .removeLabel,
                messageIds: [messageID],
                accountID: accountID,
                metadata: ["labelId": labelID]
            ))
            ToastManager.shared.show(message: isAdding ? "Label added (will sync when online)" : "Label removed (will sync when online)")
            return
        }
        do {
            try await api.modifyLabels(
                id: messageID, add: addIDs, remove: removeIDs, accountID: accountID
            )
        } catch {
            if let original { await restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            ToastManager.shared.show(message: isAdding ? "Failed to add label" : "Failed to remove label", type: .error)
        }
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
