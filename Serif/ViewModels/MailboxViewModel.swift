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
    private(set) var emails: [Email] = []

    var priorityFilterEnabled: Bool = false

    var accountID: String
    var attachmentIndexer: AttachmentIndexer?
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
    @ObservationIgnored private var messageObservation: (any DatabaseCancellable)?
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
        messageObservation?.cancel()
        enrichmentTask?.cancel()
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
            messageObservation?.cancel()
            messageObservation = nil
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
        if labelIDs != currentLabelIDs || query != currentQuery || messageObservation == nil {
            await loadFolder(labelIDs: labelIDs, query: query)
        }
        // Otherwise: sync engine handles incremental sync, ValueObservation updates UI
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
                        JOIN message_labels ml1 ON ml1.message_id = m.gmail_id AND ml1.label_id = 'INBOX'
                        JOIN message_labels ml2 ON ml2.message_id = m.gmail_id
                        WHERE m.is_read = 0 AND ml2.label_id IN (\(placeholders))
                        GROUP BY ml2.label_id
                    """, arguments: StatementArguments(categoryIds))
                    for row in rows {
                        let labelId: String = row["label_id"]
                        let count: Int = row["cnt"]
                        if let cat = InboxCategory.allCases.first(where: { $0.rawValue == labelId }) {
                            result[cat] = count
                        }
                    }
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
            markAsReadInDatabase(messageID, isRead: false)
            self.error = error.localizedDescription
        }
    }

    /// Updates DB read state for messages already marked as read by another component (e.g. EmailDetailVM).
    func applyReadLocally(_ messageIDs: [String]) {
        for id in messageIDs {
            updateLabelsInDatabase(id, addLabelIds: [], removeLabelIds: [GmailSystemLabel.unread])
            updateReadFlagInDatabase(id, isRead: true)
        }
    }

    /// Marks a message as unread. Optimistic DB write → API call → revert on failure.
    func markAsUnread(_ messageID: String) async {
        let original = updateLabelsInDatabase(messageID, addLabelIds: [GmailSystemLabel.unread], removeLabelIds: [])
        updateReadFlagInDatabase(messageID, isRead: false)
        do {
            try await api.markAsUnread(id: messageID, accountID: accountID)
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            updateReadFlagInDatabase(messageID, isRead: true)
            self.error = error.localizedDescription
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
        }
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
                    try LabelRecord(gmailId: labelId, name: labelId, type: nil, bgColor: nil, textColor: nil).insert(database, onConflict: .ignore)
                    try MessageLabelRecord(messageId: messageID, labelId: labelId).insert(database, onConflict: .ignore)
                }

                // Sync denormalized columns from final label state
                let finalLabels = try String.fetchAll(database, sql:
                    "SELECT label_id FROM message_labels WHERE message_id = ?",
                    arguments: [messageID]
                )
                try database.execute(
                    sql: "UPDATE messages SET is_read = ?, is_starred = ? WHERE gmail_id = ?",
                    arguments: [!finalLabels.contains(GmailSystemLabel.unread),
                                finalLabels.contains(GmailSystemLabel.starred),
                                messageID]
                )

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
                let isRead = !originalLabelIds.contains(GmailSystemLabel.unread)
                let isStarred = originalLabelIds.contains(GmailSystemLabel.starred)
                try database.execute(
                    sql: "UPDATE messages SET is_read = ?, is_starred = ? WHERE gmail_id = ?",
                    arguments: [isRead, isStarred, messageID]
                )
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
                    try LabelRecord(gmailId: labelId, name: labelId, type: nil, bgColor: nil, textColor: nil).insert(database, onConflict: .ignore)
                    try MessageLabelRecord(messageId: messageID, labelId: labelId).insert(database, onConflict: .ignore)
                }
                let isRead = !serverLabelIds.contains(GmailSystemLabel.unread)
                let isStarred = serverLabelIds.contains(GmailSystemLabel.starred)
                try database.execute(
                    sql: "UPDATE messages SET is_read = ?, is_starred = ? WHERE gmail_id = ?",
                    arguments: [isRead, isStarred, messageID]
                )
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
        do {
            try await action()
            // Sync engine will detect changes on next delta sync; ValueObservation updates UI.
        } catch GmailAPIError.partialFailure {
            self.error = "Some messages could not be deleted"
        } catch {
            self.error = error.localizedDescription
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
        }
    }

    /// Adds a label to a message. Optimistic DB write → API call → revert on failure.
    func addLabel(_ labelID: String, to messageID: String) async {
        let original = updateLabelsInDatabase(messageID, addLabelIds: [labelID], removeLabelIds: [])
        do {
            try await api.modifyLabels(
                id: messageID, add: [labelID], remove: [], accountID: accountID
            )
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
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
            return nil
        }
    }

    /// Removes a label from a message. Optimistic DB write → API call → revert on failure.
    func removeLabel(_ labelID: String, from messageID: String) async {
        let original = updateLabelsInDatabase(messageID, addLabelIds: [], removeLabelIds: [labelID])
        do {
            try await api.modifyLabels(
                id: messageID, add: [], remove: [labelID], accountID: accountID
            )
        } catch {
            if let original { restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            self.error = error.localizedDescription
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

    // MARK: - Private helpers

    /// Combined label + read flag update in a single transaction.
    /// Returns original label IDs for undo. Avoids double ValueObservation notifications.
    @discardableResult
    private func markAsReadInDatabase(_ messageID: String, isRead: Bool) -> [String]? {
        guard let db = mailDatabase else { return nil }
        do {
            return try db.dbPool.write { database in
                // Read current labels for undo
                let currentLabels = try String.fetchAll(database, sql:
                    "SELECT label_id FROM message_labels WHERE message_id = ?",
                    arguments: [messageID]
                )

                // Update label associations: add/remove UNREAD label
                if isRead {
                    try database.execute(
                        sql: "DELETE FROM message_labels WHERE message_id = ? AND label_id = ?",
                        arguments: [messageID, GmailSystemLabel.unread]
                    )
                } else {
                    try LabelRecord(gmailId: GmailSystemLabel.unread, name: GmailSystemLabel.unread, type: nil, bgColor: nil, textColor: nil)
                        .insert(database, onConflict: .ignore)
                    try MessageLabelRecord(messageId: messageID, labelId: GmailSystemLabel.unread)
                        .insert(database, onConflict: .ignore)
                }

                // Update denormalized read flag
                try database.execute(
                    sql: "UPDATE messages SET is_read = ? WHERE gmail_id = ?",
                    arguments: [isRead, messageID]
                )

                return currentLabels
            }
        } catch {
            Self.logger.error("Combined mark-as-read DB update failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Optimistically updates the is_read flag in the database.
    private func updateReadFlagInDatabase(_ messageID: String, isRead: Bool) {
        guard let db = mailDatabase else { return }
        do {
            try db.dbPool.write { database in
                try database.execute(
                    sql: "UPDATE messages SET is_read = ? WHERE gmail_id = ?",
                    arguments: [isRead, messageID]
                )
                // Also update label associations: add/remove UNREAD label
                if isRead {
                    try database.execute(
                        sql: "DELETE FROM message_labels WHERE message_id = ? AND label_id = ?",
                        arguments: [messageID, GmailSystemLabel.unread]
                    )
                } else {
                    try MessageLabelRecord(messageId: messageID, labelId: GmailSystemLabel.unread)
                        .insert(database, onConflict: .ignore)
                }
            }
        } catch {
            Self.logger.error("Read flag DB update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

}
