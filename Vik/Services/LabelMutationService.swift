private import GRDB
private import os
import SwiftUI

/// Per-message label mutation logic: reads current labels, applies a transform, writes results,
/// and syncs denormalized `is_read`/`is_starred` columns via `MailDatabaseQueries.rebuildLabels`.
/// Called inside an existing write transaction — does **not** open one itself.
/// Returns the **original** label IDs (before the transform) for undo.
///
/// File-scope to avoid `@MainActor` isolation inheritance from `LabelMutationService`.
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

/// Encapsulates database label mutations and API mutation proxying for email messages.
///
/// Extracted from `MailboxViewModel` to enforce single responsibility:
/// - DB label writes (writeLabels, updateLabelsInDatabase, batch, restore, reconcile, removeAll)
/// - API mutation proxying (markAsRead, toggleStar, trash, archive, emptyTrash, etc.)
///
/// Dependencies: `MailDatabase` (for DB writes), `MessageFetching` (for API calls).
/// `MailboxViewModel` owns an instance and exposes it as `labelMutations`.
@Observable
@MainActor
final class LabelMutationService {
    @ObservationIgnored private(set) var mailDatabase: MailDatabase?
    @ObservationIgnored private(set) var backgroundSyncer: BackgroundSyncer?
    /// Set by `restoreLabelsInDatabase` so the UI can re-select the restored email.
    var lastRestoredMessageID: String?

    var accountID: String
    private let api: MessageFetching

    /// Called after mutations that affect unread counts (mark read, archive, etc.)
    /// so the owning MailboxViewModel can refresh folder counts and dock badge.
    @ObservationIgnored var onUnreadCountsChanged: (() async -> Void)?

    nonisolated private static let logger = Logger(category: "LabelMutation")

    init(
        accountID: String,
        api: MessageFetching = GmailMessageService.shared
    ) {
        self.accountID = accountID
        self.api = api
    }

    func setMailDatabase(_ db: MailDatabase?) {
        self.mailDatabase = db
    }

    func setBackgroundSyncer(_ syncer: BackgroundSyncer?) {
        self.backgroundSyncer = syncer
    }

    /// Refreshes unread counts and dock badge. Called internally after mutations that
    /// affect read/inbox state.
    private func refreshUnreadCounts() async {
        await MailboxViewModel.updateDockBadge()
        await onUnreadCountsChanged?()
    }

    // MARK: - Label mutation helpers

    /// Core label-mutation helper. Reads current labels, applies a transform, writes results,
    /// and syncs denormalized `is_read`/`is_starred` columns — all in a single write transaction.
    /// Returns the **original** label IDs (before the transform) for undo, or `nil` on failure.
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

    // MARK: - Mutations (internal — use EmailActionCoordinator for user-facing actions)

    /// Shared optimistic-update flow: write labels to DB, call API, revert on failure.
    ///
    /// 1. Applies `addLabelIDs` / `removeLabelIDs` to the message's labels in the DB.
    /// 2. Calls `apiCall` (which may also reconcile server labels on success).
    /// 3. On failure: reverts to original labels, shows a toast.
    @discardableResult
    private func performOptimisticAction(
        _ messageID: String,
        addLabelIDs: [String] = [],
        removeLabelIDs: [String] = [],
        apiCall: () async throws -> Void,
        failureToast: String
    ) async -> Bool {
        let original = await updateLabelsInDatabase(messageID, addLabelIds: addLabelIDs, removeLabelIds: removeLabelIDs)

        // Clear delivered notification & refresh badge when marking read or removing from inbox
        let affectsUnread = removeLabelIDs.contains(GmailSystemLabel.unread)
            || removeLabelIDs.contains(GmailSystemLabel.inbox)
        if affectsUnread {
            NotificationService.shared.removeDeliveredNotification(messageId: messageID)
            await refreshUnreadCounts()
        }

        do {
            try await apiCall()
            return true
        } catch {
            if let original { await restoreLabelsInDatabase(messageID, originalLabelIds: original) }
            ToastManager.shared.show(message: failureToast, type: .error)
            // Revert badge on failure
            if affectsUnread {
                await refreshUnreadCounts()
            }
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
            // Clear delivered notifications for messages marked read and refresh badge
            NotificationService.shared.removeDeliveredNotifications(messageIds: messageIDs)
            await refreshUnreadCounts()
        } catch {
            Self.logger.error("Batch applyReadLocally failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Marks a message as unread. Optimistic DB write → API call → revert on failure.
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

    /// Permanently deletes all messages in Trash.
    func emptyTrash(confirmedCount: Int) async {
        await emptyFolder(labelID: GmailSystemLabel.trash, folderName: "Trash", confirmedCount: confirmedCount) { [api, accountID] in
            try await api.emptyTrash(accountID: accountID)
        }
    }

    /// Permanently deletes all messages in Spam.
    func emptySpam(confirmedCount: Int) async {
        await emptyFolder(labelID: GmailSystemLabel.spam, folderName: "Spam", confirmedCount: confirmedCount) { [api, accountID] in
            try await api.emptySpam(accountID: accountID)
        }
    }

    private func emptyFolder(labelID: String, folderName: String, confirmedCount: Int, action: @Sendable () async throws -> Void) async {
        // 1. Optimistic: remove all messages with this label from local DB immediately.
        //    ValueObservation picks up the change → UI animates messages out.
        _ = await deleteMessagesByLabel(labelID)
        await onUnreadCountsChanged?()

        // 2. Call the API to delete on server.
        do {
            try await action()
            // Use the server-side count from the confirmation dialog, not the local DB count,
            // since only a subset of server messages may be synced locally.
            ToastManager.shared.show(
                message: "\(confirmedCount) message\(confirmedCount == 1 ? "" : "s") deleted from \(folderName)"
            )
        } catch GoogleAPIError.partialFailure(let failedCount) {
            ToastManager.shared.show(message: "\(failedCount) messages could not be deleted", type: .error)
        } catch {
            ToastManager.shared.show(message: "Failed to empty \(folderName.lowercased())", type: .error)
            // Messages will reappear on next delta sync if API failed.
        }
    }

    /// Deletes all message records that carry the given label from the local database.
    /// Returns the number of messages deleted.
    private func deleteMessagesByLabel(_ labelID: String) async -> Int {
        guard let db = mailDatabase else { return 0 }
        do {
            if let syncer = backgroundSyncer {
                // Use BackgroundSyncer for consistent FTS cleanup and thread count updates.
                let ids = try await db.dbPool.read { database in
                    try String.fetchAll(database, sql:
                        "SELECT message_id FROM message_labels WHERE label_id = ?",
                        arguments: [labelID]
                    )
                }
                guard !ids.isEmpty else { return 0 }
                try await syncer.deleteMessages(gmailIds: ids)
                return ids.count
            } else {
                return try await db.dbPool.write { database in
                    let ids = try String.fetchAll(database, sql:
                        "SELECT message_id FROM message_labels WHERE label_id = ?",
                        arguments: [labelID]
                    )
                    guard !ids.isEmpty else { return 0 }
                    // Collect thread IDs before deletion for count updates.
                    var affectedThreadIds = Set<String>()
                    let chunkSize = 1000
                    for chunkStart in stride(from: 0, to: ids.count, by: chunkSize) {
                        let chunk = Array(ids[chunkStart..<min(chunkStart + chunkSize, ids.count)])
                        let threadIds = try Set(String.fetchAll(database, sql:
                            "SELECT DISTINCT thread_id FROM messages WHERE gmail_id IN (\(chunk.sqlPlaceholders))",
                            arguments: StatementArguments(chunk)
                        ))
                        affectedThreadIds.formUnion(threadIds)
                    }
                    // CASCADE handles message_labels, email_tags, attachments.
                    try MessageRecord.deleteAll(database, keys: ids)
                    try MailDatabaseQueries.updateThreadCounts(for: affectedThreadIds, in: database)
                    return ids.count
                }
            }
        } catch {
            Self.logger.error("Failed to delete messages by label \(labelID): \(error)")
            return 0
        }
    }

    /// Moves a message to inbox. Optimistic DB write → API call → revert on failure.
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
    func addLabel(_ labelID: String, to messageID: String) async {
        await modifyLabel(labelID, on: messageID, isAdding: true)
    }

    /// Creates a new label and adds it to a message.
    /// Returns the created label ID, or nil on failure.
    /// - Parameter appendLabel: Called with the newly created label so the caller can update its label list.
    @discardableResult
    func createAndAddLabel(name: String, to messageID: String, appendLabel: (GmailLabel) -> Void) async -> String? {
        do {
            let newLabel = try await GmailLabelService.shared.createLabel(name: name, accountID: accountID)
            appendLabel(newLabel)
            await addLabel(newLabel.id, to: messageID)
            return newLabel.id
        } catch {
            ToastManager.shared.show(message: "Failed to create label", type: .error)
            return nil
        }
    }

    /// Removes a user label from a message. Handles optimistic DB update, offline queue, and API call.
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
}
