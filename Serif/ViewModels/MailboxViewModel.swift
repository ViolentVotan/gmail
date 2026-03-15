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
///
/// DB-only architecture: folder loads start a `ValueObservation` on the label;
/// the sync engine populates the database, and observation drives the UI.
@Observable
@MainActor
final class MailboxViewModel {
    var isLoading      = false
    var error:         String?
    var labels:        [GmailLabel] = []
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

    var accountID: String
    private var currentLabelIDs: [String] = [GmailSystemLabel.inbox]
    private var currentQuery:    String?

    // MARK: - Services

    private(set) var mailDatabase: MailDatabase?
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
    private let labelService: LabelSyncService
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var enrichmentTask: Task<Void, Never>?

    init(
        accountID: String,
        api: MessageFetching = GmailMessageService.shared
    ) {
        self.accountID = accountID
        self.api = api
        self.labelService = LabelSyncService.shared
    }

    deinit {
        observationTask?.cancel()
        enrichmentTask?.cancel()
    }

    // MARK: - Database Observation

    func startObservingLabel(_ labelId: String) {
        observationTask?.cancel()
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
        // Use trackingConstantRegion: the set of tracked tables is fixed for a
        // given label observation, so GRDB only computes the region once. This
        // avoids spurious refreshes when unrelated rows in the labels table are
        // upserted during sync.
        let observation = ValueObservation.trackingConstantRegion { db in
            try request.fetchAll(db)
        }
        observationTask = Task { @MainActor [weak self] in
            do {
                for try await records in observation.values(in: db.dbPool) {
                    self?.handleDatabaseUpdate(records, from: db)
                }
            } catch {
                self?.error = "Database observation failed: \(error.localizedDescription)"
                ToastManager.shared.show(message: "Database observation failed", type: .error)
            }
        }
    }

    private func handleDatabaseUpdate(_ records: [MessageWithAssociations], from db: MailDatabase) {
        // Stale check: ignore updates from a previous account's database
        guard db === mailDatabase else { return }
        enrichmentTask?.cancel()
        enrichmentTask = Task { @MainActor in
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
            var latest = threadEmails.max(by: { $0.date < $1.date })
            latest?.threadMessageCount = threadEmails.map(\.threadMessageCount).max() ?? threadEmails.count
            return latest
        }.sorted { $0.date > $1.date }
    }

    // MARK: - Load

    /// Loads a folder by starting a DB observation on the label.
    /// Search queries are handled via FTS + API.
    func loadFolder(labelIDs: [String], query: String? = nil) async {
        currentLabelIDs = labelIDs
        currentQuery = query

        if let query, !query.isEmpty {
            // Search still uses FTS for local, API for server-side
            await search(query: query)
            return
        }

        // DB-only path: start observing the label
        if let labelId = labelIDs.first, mailDatabase != nil {
            startObservingLabel(labelId)
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

    // MARK: - Labels & Metadata

    func loadLabels() async {
        let result = await labelService.loadLabels(accountID: accountID, currentLabels: labels)
        labels = result.labels
        if let err = result.error {
            error = err
            ToastManager.shared.show(message: "Failed to load labels", type: .error)
        }
    }

    func loadSendAs() async {
        let result = await labelService.loadSendAs(accountID: accountID)
        sendAsAliases = result.aliases
        if let err = result.error {
            error = err
            ToastManager.shared.show(message: "Failed to load send-as aliases", type: .error)
        }
    }

    func renameLabel(_ label: GmailLabel, to newName: String) async {
        if let idx = labels.firstIndex(where: { $0.id == label.id }) {
            let updated = GmailLabel(id: label.id, name: newName, type: label.type,
                                      messagesTotal: label.messagesTotal, messagesUnread: label.messagesUnread,
                                      threadsTotal: label.threadsTotal, threadsUnread: label.threadsUnread,
                                      color: label.color,
                                      labelListVisibility: label.labelListVisibility,
                                      messageListVisibility: label.messageListVisibility)
            labels[idx] = updated
        }
        do {
            let fresh = try await GmailLabelService.shared.updateLabel(id: label.id, newName: newName, accountID: accountID)
            if let idx = labels.firstIndex(where: { $0.id == fresh.id }) { labels[idx] = fresh }
        } catch {
            if let idx = labels.firstIndex(where: { $0.id == label.id }) { labels[idx] = label }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to rename label", type: .error)
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
            ToastManager.shared.show(message: "Failed to delete label", type: .error)
        }
    }

    func loadCategoryUnreadCounts() async {
        if let db = mailDatabase {
            do {
                let counts = try await db.dbPool.read { database in
                    var result: [InboxCategory: Int] = [:]
                    let categoryIds = InboxCategory.allCases
                        .filter { $0 != .all }
                        .map { $0.rawValue }
                    let placeholders = categoryIds.map { _ in "?" }.joined(separator: ",")
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
                return
            } catch {
                // Fall through to API
            }
        }
        if let counts = await labelService.loadCategoryUnreadCounts(accountID: accountID) {
            categoryUnreadCounts = counts
        }
    }

    // MARK: - Account switching

    func switchAccount(_ id: String) async {
        observationTask?.cancel()
        observationTask = nil
        enrichmentTask?.cancel()
        enrichmentTask = nil
        accountID = id
        error     = nil
        emails    = []
    }

    // MARK: - Mutations

    /// Marks a message as read. Optimistic DB write → API call → revert on failure.
    /// Uses a single transaction to update both labels and read flag, avoiding double ValueObservation notifications.
    func markAsRead(_ messageID: String) async {
        let original = markAsReadInDatabase(messageID, isRead: true)
        do {
            try await api.markAsRead(id: messageID, accountID: accountID)
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to mark as read", type: .error)
        }
    }

    /// Updates DB read state for messages already marked as read by another component (e.g. EmailDetailVM).
    /// Batches all updates in a single write transaction to avoid N separate ValueObservation notifications.
    func applyReadLocally(_ messageIDs: [String]) {
        guard let db = mailDatabase, !messageIDs.isEmpty else { return }
        do {
            try db.dbPool.write { database in
                for id in messageIDs {
                    // Remove UNREAD label
                    try database.execute(
                        sql: "DELETE FROM message_labels WHERE message_id = ? AND label_id = ?",
                        arguments: [id, GmailSystemLabel.unread]
                    )
                    // Sync denormalized is_read flag
                    try database.execute(
                        sql: "UPDATE messages SET is_read = 1 WHERE gmail_id = ?",
                        arguments: [id]
                    )
                }
            }
        } catch {
            Self.logger.error("Batch applyReadLocally failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Marks a message as unread. Optimistic DB write → API call → revert on failure.
    func markAsUnread(_ messageID: String) async {
        let original = updateLabelsInDatabase(messageID, addLabelIds: [GmailSystemLabel.unread], removeLabelIds: [])
        do {
            try await api.markAsUnread(id: messageID, accountID: accountID)
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to mark as unread", type: .error)
        }
    }

    /// Toggles star on a message. Optimistic DB write → API call → revert on failure.
    func toggleStar(_ messageID: String, isStarred: Bool) async {
        let addLabels = isStarred ? [String]() : [GmailSystemLabel.starred]
        let removeLabels = isStarred ? [GmailSystemLabel.starred] : [String]()
        let original = updateLabelsInDatabase(messageID, addLabelIds: addLabels, removeLabelIds: removeLabels)
        do {
            try await api.setStarred(!isStarred, id: messageID, accountID: accountID)
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to toggle star", type: .error)
        }
    }

    /// Trashes a message. Optimistic DB write → API call → reconcile or revert.
    func trash(_ messageID: String) async {
        let original = updateLabelsInDatabase(messageID, addLabelIds: [GmailSystemLabel.trash], removeLabelIds: [GmailSystemLabel.inbox])
        do {
            let updated = try await api.trashMessage(id: messageID, accountID: accountID)
            reconcileLabelsInDatabase(messageID, serverLabelIds: updated.labelIds ?? [])
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to trash message", type: .error)
        }
    }

    /// Archives a message. Optimistic DB write → API call → revert on failure.
    func archive(_ messageID: String) async {
        let original = updateLabelsInDatabase(messageID, addLabelIds: [], removeLabelIds: [GmailSystemLabel.inbox])
        do {
            try await api.archiveMessage(id: messageID, accountID: accountID)
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to archive", type: .error)
        }
    }

    // MARK: - Label mutation helper

    /// Core label-mutation helper. Reads current labels, applies a transform, writes results,
    /// and syncs denormalized `is_read`/`is_starred` columns — all in a single write transaction.
    /// Returns the **original** label IDs (before the transform) for undo, or `nil` on failure.
    ///
    /// - Parameters:
    ///   - messageID: The Gmail message ID.
    ///   - ensureLabelRecords: When `true`, upserts `LabelRecord` rows for every label in the
    ///     final set (needed when labels may not yet exist in the `labels` table).
    ///   - transform: Mutates the current label set in place.
    @discardableResult
    private func writeLabels(
        _ messageID: String,
        ensureLabelRecords: Bool = false,
        transform: (inout Set<String>) -> Void
    ) -> [String]? {
        guard let db = mailDatabase else { return nil }
        do {
            return try db.dbPool.write { database in
                // 1. Read current labels
                let currentLabels = try String.fetchAll(database, sql:
                    "SELECT label_id FROM message_labels WHERE message_id = ?",
                    arguments: [messageID]
                )
                var labels = Set(currentLabels)

                // 2. Apply transform
                transform(&labels)

                // 3. Delete all label rows for this message
                try database.execute(
                    sql: "DELETE FROM message_labels WHERE message_id = ?",
                    arguments: [messageID]
                )

                // 4. Insert new label rows
                for labelId in labels {
                    if ensureLabelRecords {
                        try LabelRecord(gmailId: labelId, name: labelId, type: nil, bgColor: nil, textColor: nil)
                            .insert(database, onConflict: .ignore)
                    }
                    try MessageLabelRecord(messageId: messageID, labelId: labelId)
                        .insert(database, onConflict: .ignore)
                }

                // 5. Sync denormalized columns
                let isRead = !labels.contains(GmailSystemLabel.unread)
                let isStarred = labels.contains(GmailSystemLabel.starred)
                try database.execute(
                    sql: "UPDATE messages SET is_read = ?, is_starred = ? WHERE gmail_id = ?",
                    arguments: [isRead, isStarred, messageID]
                )

                return currentLabels
            }
        } catch {
            Self.logger.error("DB label mutation failed for \(messageID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Optimistically updates labels in the database so ValueObservation reflects the change.
    /// Returns the original label IDs for undo.
    @discardableResult
    func updateLabelsInDatabase(_ messageID: String, addLabelIds: [String], removeLabelIds: [String]) -> [String]? {
        writeLabels(messageID, ensureLabelRecords: true) { labels in
            labels.subtract(removeLabelIds)
            labels.formUnion(addLabelIds)
        }
    }

    /// Removes all labels from a message in the database. Returns the original labels for undo.
    func removeAllLabelsInDatabase(_ messageID: String) -> [String]? {
        writeLabels(messageID) { labels in
            labels.removeAll()
        }
    }

    /// Restores the original labels in the database (undo path).
    func restoreLabelsInDatabase(_ messageID: String, originalLabelIds: [String]) {
        writeLabels(messageID) { labels in
            labels = Set(originalLabelIds)
        }
    }

    /// Reconciles DB labels with the server's authoritative label set after an API mutation.
    /// Corrects any drift between our optimistic update and what the server actually applied.
    private func reconcileLabelsInDatabase(_ messageID: String, serverLabelIds: [String]) {
        writeLabels(messageID, ensureLabelRecords: true) { labels in
            labels = Set(serverLabelIds)
        }
    }

    func emptyTrash() async {
        await emptyFolder { [api, accountID] in try await api.emptyTrash(accountID: accountID) }
    }

    func emptySpam() async {
        await emptyFolder { [api, accountID] in try await api.emptySpam(accountID: accountID) }
    }

    private func emptyFolder(action: @Sendable () async throws -> Void) async {
        do {
            try await action()
            // Sync engine will detect changes on next delta sync; ValueObservation updates UI.
        } catch GmailAPIError.partialFailure {
            self.error = "Some messages could not be deleted"
            ToastManager.shared.show(message: "Some messages could not be deleted", type: .error)
        } catch {
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to empty folder", type: .error)
        }
    }

    /// Moves a message to inbox. Optimistic DB write → API call → revert on failure.
    func moveToInbox(_ messageID: String) async {
        let original = updateLabelsInDatabase(messageID, addLabelIds: [GmailSystemLabel.inbox], removeLabelIds: [])
        do {
            try await api.modifyLabels(
                id: messageID, add: [GmailSystemLabel.inbox], remove: [], accountID: accountID
            )
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to move to inbox", type: .error)
        }
    }

    /// Untrashes a message. Optimistic DB write → API call → reconcile or revert.
    func untrash(_ messageID: String) async {
        let original = updateLabelsInDatabase(messageID, addLabelIds: [], removeLabelIds: [GmailSystemLabel.trash])
        do {
            let updated = try await api.untrashMessage(id: messageID, accountID: accountID)
            reconcileLabelsInDatabase(messageID, serverLabelIds: updated.labelIds ?? [])
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to untrash", type: .error)
        }
    }

    /// Permanently deletes a message. Removes all labels from DB optimistically,
    /// then deletes the message record itself after a successful API call.
    func deletePermanently(_ messageID: String) async {
        let original = removeAllLabelsInDatabase(messageID)
        do {
            try await api.deleteMessagePermanently(id: messageID, accountID: accountID)
            // Delete the message record (CASCADE handles message_labels, email_tags, attachments).
            // Use BackgroundSyncer when available for FTS cleanup; fall back to direct delete.
            if let syncer = backgroundSyncer {
                try? await syncer.deleteMessages(gmailIds: [messageID])
            } else {
                try? await mailDatabase?.dbPool.write { db in
                    try FTSManager.delete(gmailId: messageID, in: db)
                    try MessageRecord.deleteOne(db, key: messageID)
                }
            }
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to delete permanently", type: .error)
        }
    }

    /// Marks a message as not spam. Optimistic DB write → API call → revert on failure.
    func unspam(_ messageID: String) async {
        let original = updateLabelsInDatabase(messageID, addLabelIds: [GmailSystemLabel.inbox], removeLabelIds: [GmailSystemLabel.spam])
        do {
            try await api.modifyLabels(
                id: messageID, add: [GmailSystemLabel.inbox], remove: [GmailSystemLabel.spam], accountID: accountID
            )
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to remove spam", type: .error)
        }
    }

    /// Marks a message as spam. Optimistic DB write → API call → revert on failure.
    func spam(_ messageID: String) async {
        let original = updateLabelsInDatabase(messageID, addLabelIds: [GmailSystemLabel.spam], removeLabelIds: [GmailSystemLabel.inbox])
        do {
            try await api.spamMessage(id: messageID, accountID: accountID)
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to mark as spam", type: .error)
        }
    }

    /// Adds a label to a message. Optimistic DB write → offline queue or API call → revert on failure.
    func addLabel(_ labelID: String, to messageID: String) async {
        let original = updateLabelsInDatabase(messageID, addLabelIds: [labelID], removeLabelIds: [])
        guard NetworkMonitor.shared.isConnected else {
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: .addLabel, messageIds: [messageID], accountID: accountID,
                metadata: ["labelId": labelID]
            ))
            ToastManager.shared.show(message: "Label added (will sync when online)")
            return
        }
        do {
            try await api.modifyLabels(
                id: messageID, add: [labelID], remove: [], accountID: accountID
            )
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to add label", type: .error)
        }
    }

    @discardableResult
    func createAndAddLabel(name: String, to messageID: String) async -> String? {
        do {
            let newLabel = try await GmailLabelService.shared.createLabel(name: name, accountID: accountID)
            labels.append(newLabel)
            await addLabel(newLabel.id, to: messageID)
            return newLabel.id
        } catch {
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to create label", type: .error)
            return nil
        }
    }

    /// Removes a label from a message. Optimistic DB write → offline queue or API call → revert on failure.
    func removeLabel(_ labelID: String, from messageID: String) async {
        let original = updateLabelsInDatabase(messageID, addLabelIds: [], removeLabelIds: [labelID])
        guard NetworkMonitor.shared.isConnected else {
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: .removeLabel, messageIds: [messageID], accountID: accountID,
                metadata: ["labelId": labelID]
            ))
            ToastManager.shared.show(message: "Label removed (will sync when online)")
            return
        }
        do {
            try await api.modifyLabels(
                id: messageID, add: [], remove: [labelID], accountID: accountID
            )
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
            ToastManager.shared.show(message: "Failed to remove label", type: .error)
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

    // MARK: - Private helpers

    /// Combined label + read flag update in a single transaction.
    /// Returns original label IDs for undo. Avoids double ValueObservation notifications.
    @discardableResult
    private func markAsReadInDatabase(_ messageID: String, isRead: Bool) -> [String]? {
        writeLabels(messageID, ensureLabelRecords: !isRead) { labels in
            if isRead {
                labels.remove(GmailSystemLabel.unread)
            } else {
                labels.insert(GmailSystemLabel.unread)
            }
        }
    }

}
