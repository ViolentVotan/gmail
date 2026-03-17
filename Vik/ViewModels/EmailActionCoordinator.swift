import SwiftUI

@Observable
@MainActor
final class EmailActionCoordinator {
    let mailboxViewModel: MailboxViewModel
    let mailStore: MailStore
    private let api: any MessageFetching

    init(mailboxViewModel: MailboxViewModel, mailStore: MailStore, api: any MessageFetching = GmailMessageService.shared) {
        self.mailboxViewModel = mailboxViewModel
        self.mailStore = mailStore
        self.api = api
    }

    // MARK: - Network / Offline state

    var isConnected: Bool { NetworkMonitor.shared.isConnected }
    var pendingOfflineActionCount: Int { OfflineActionQueue.shared.pendingCount }

    // MARK: - Undoable action helper

    /// Shared flow for single-email actions that follow the optimistic-update + undo pattern:
    /// guard msgID → optimistic DB update → selectNext → offline queue OR schedule undo.
    ///
    /// - Parameter offlineType: When non-nil, enqueues an offline action if disconnected.
    ///   When `nil`, the action requires connectivity — shows `offlineToast` as an error and returns early
    ///   before any DB mutation.
    private func performUndoableAction(
        email: Email,
        label: String,
        addLabels: [String],
        removeLabels: [String],
        selectNext: (Email?) -> Void,
        offlineType: OfflineAction.ActionType? = nil,
        offlineToast: String,
        apiAction: @escaping (String) async -> Void
    ) async {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        // Connectivity-required actions bail out before any DB mutation
        if offlineType == nil, !NetworkMonitor.shared.isConnected {
            ToastManager.shared.show(message: offlineToast, type: .error)
            return
        }
        let originalLabels = await vm.updateLabelsInDatabase(msgID, addLabelIds: addLabels, removeLabelIds: removeLabels)
        selectNext(nil)
        if let offlineType, !NetworkMonitor.shared.isConnected {
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: offlineType, messageIds: [msgID], accountID: vm.accountID
            ))
            ToastManager.shared.show(message: offlineToast)
            return
        }
        let expectedAccountID = vm.accountID
        UndoActionManager.shared.schedule(
            label: label,
            onConfirm: { [weak vm] in Task {
                guard let vm, vm.accountID == expectedAccountID else { return }
                guard AccountStore.shared.accounts.contains(where: { $0.id == expectedAccountID }) else { return }
                await apiAction(msgID)
            } },
            onUndo: { [weak vm] in Task {
                guard let vm, vm.accountID == expectedAccountID else { return }
                guard AccountStore.shared.accounts.contains(where: { $0.id == expectedAccountID }) else { return }
                if let labels = originalLabels {
                    await vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels)
                    vm.lastRestoredMessageID = msgID
                }
            } }
        )
    }

    // MARK: - Single email actions

    func archiveEmail(_ email: Email, selectNext: (Email?) -> Void) async {
        await performUndoableAction(
            email: email,
            label: "Archived",
            addLabels: [],
            removeLabels: [GmailSystemLabel.inbox],
            selectNext: selectNext,
            offlineType: .archive,
            offlineToast: "Archived (will sync when online)",
            apiAction: { [mailboxViewModel] msgID in await mailboxViewModel.archive(msgID) }
        )
    }

    func deleteEmail(_ email: Email, selectNext: (Email?) -> Void) async {
        // Draft-specific path: delete from mailStore (remote deletion handled inside deleteDraft).
        if email.isDraft {
            mailStore.deleteDraft(id: email.id, accountID: mailboxViewModel.accountID)
            selectNext(nil)
            return
        }
        await performUndoableAction(
            email: email,
            label: "Moved to Trash",
            addLabels: [GmailSystemLabel.trash],
            removeLabels: [GmailSystemLabel.inbox],
            selectNext: selectNext,
            offlineType: .trash,
            offlineToast: "Moved to Trash (will sync when online)",
            apiAction: { [mailboxViewModel] msgID in await mailboxViewModel.trash(msgID) }
        )
    }

    func toggleStarEmail(_ email: Email) async {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        guard NetworkMonitor.shared.isConnected else {
            let actionType: OfflineAction.ActionType = email.isStarred ? .unstar : .star
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: actionType, messageIds: [msgID], accountID: vm.accountID
            ))
            // Optimistic DB update so UI reflects the change immediately
            _ = await vm.updateLabelsInDatabase(
                msgID,
                addLabelIds: email.isStarred ? [] : [GmailSystemLabel.starred],
                removeLabelIds: email.isStarred ? [GmailSystemLabel.starred] : []
            )
            ToastManager.shared.show(message: email.isStarred ? "Unstarred (will sync when online)" : "Starred (will sync when online)")
            return
        }
        await vm.toggleStar(msgID, isStarred: email.isStarred)
    }

    func markReadEmail(_ email: Email) async {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        guard NetworkMonitor.shared.isConnected else {
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: .markRead, messageIds: [msgID], accountID: vm.accountID
            ))
            _ = await vm.updateLabelsInDatabase(msgID, addLabelIds: [], removeLabelIds: [GmailSystemLabel.unread])
            ToastManager.shared.show(message: "Marked read (will sync when online)")
            return
        }
        await vm.markAsRead(msgID)
    }

    func markUnreadEmail(_ email: Email) async {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        guard NetworkMonitor.shared.isConnected else {
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: .markUnread, messageIds: [msgID], accountID: vm.accountID
            ))
            // Optimistic DB update
            _ = await vm.updateLabelsInDatabase(msgID, addLabelIds: [GmailSystemLabel.unread], removeLabelIds: [])
            ToastManager.shared.show(message: "Marked unread (will sync when online)")
            return
        }
        await vm.markAsUnread(msgID)
    }

    func markSpamEmail(_ email: Email, selectNext: @escaping (Email?) -> Void) async {
        await performUndoableAction(
            email: email,
            label: "Marked as Spam",
            addLabels: [GmailSystemLabel.spam],
            removeLabels: [GmailSystemLabel.inbox],
            selectNext: selectNext,
            offlineType: .spam,
            offlineToast: "Marked as Spam (will sync when online)",
            apiAction: { [mailboxViewModel] msgID in await mailboxViewModel.spam(msgID) }
        )
    }

    func unsubscribeEmail(_ email: Email) {
        guard let url = email.unsubscribeURL else { return }
        SubscriptionsStore.shared.removeEntry(for: email)
        Task { await UnsubscribeService.shared.unsubscribe(url: url, oneClick: false) }
    }

    func unsubscribe(url: URL, oneClick: Bool, messageID: String?, accountID: String) async -> Bool {
        await UnsubscribeService.shared.unsubscribe(url: url, oneClick: oneClick, messageID: messageID, accountID: accountID)
    }

    func isUnsubscribed(messageID: String, accountID: String) -> Bool {
        UnsubscribeService.shared.isUnsubscribed(messageID: messageID, accountID: accountID)
    }

    func extractBodyUnsubscribeURL(from html: String) -> URL? {
        UnsubscribeService.extractBodyUnsubscribeURL(from: html)
    }

    func loadDraft(id: String, accountID: String, format: String = "full") async throws -> GmailDraft? {
        try await GmailDraftService.shared.getDraft(id: id, accountID: accountID, format: format)
    }

    func moveToInboxEmail(_ email: Email, selectedFolder: Folder, selectNext: (Email?) -> Void) async {
        let removeLabels = selectedFolder == .trash ? [GmailSystemLabel.trash] : [String]()
        let apiAction: (String) async -> Void = selectedFolder == .trash
            ? { [mailboxViewModel] msgID in await mailboxViewModel.untrash(msgID) }
            : { [mailboxViewModel] msgID in await mailboxViewModel.moveToInbox(msgID) }
        await performUndoableAction(
            email: email,
            label: "Moved to Inbox",
            addLabels: [GmailSystemLabel.inbox],
            removeLabels: removeLabels,
            selectNext: selectNext,
            offlineToast: "Move to Inbox requires internet connection",
            apiAction: apiAction
        )
    }

    /// Permanently deletes a message. Cannot use `performUndoableAction` because it calls
    /// `removeAllLabelsInDatabase` (not a label add/remove transform) and its confirm action
    /// invokes `deletePermanently` which deletes the message record itself.
    func deletePermanentlyEmail(_ email: Email, selectNext: (Email?) -> Void) async {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        guard NetworkMonitor.shared.isConnected else {
            ToastManager.shared.show(message: "Permanent delete requires internet connection", type: .error)
            return
        }
        // Remove all labels from DB so ValueObservation won't bring it back
        let originalLabels = await vm.removeAllLabelsInDatabase(msgID)
        selectNext(nil)
        let expectedAccountID = vm.accountID
        UndoActionManager.shared.schedule(
            label: "Deleted permanently",
            onConfirm: { [weak vm] in Task {
                guard let vm, vm.accountID == expectedAccountID else { return }
                guard AccountStore.shared.accounts.contains(where: { $0.id == expectedAccountID }) else { return }
                await vm.deletePermanently(msgID, originalLabelIds: originalLabels)
            } },
            onUndo: { [weak vm] in Task {
                guard let vm, vm.accountID == expectedAccountID else { return }
                guard AccountStore.shared.accounts.contains(where: { $0.id == expectedAccountID }) else { return }
                if let labels = originalLabels {
                    await vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels)
                    vm.lastRestoredMessageID = msgID
                }
            } }
        )
    }

    func markNotSpamEmail(_ email: Email, selectNext: (Email?) -> Void) async {
        await performUndoableAction(
            email: email,
            label: "Moved to Inbox",
            addLabels: [GmailSystemLabel.inbox],
            removeLabels: [GmailSystemLabel.spam],
            selectNext: selectNext,
            offlineToast: "Not Spam requires internet connection",
            apiAction: { [mailboxViewModel] msgID in await mailboxViewModel.unspam(msgID) }
        )
    }

    /// Snoozes a message. Cannot use `performUndoableAction` because its confirm action
    /// performs SnoozeStore operations and an archive — not a simple label API call.
    func snoozeEmail(_ email: Email, until date: Date, selectNext: (Email?) -> Void) async {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        guard NetworkMonitor.shared.isConnected else {
            ToastManager.shared.show(message: "Snooze requires internet connection", type: .error)
            return
        }
        // Optimistic DB write: remove from inbox so ValueObservation hides it
        let originalLabels = await vm.updateLabelsInDatabase(
            msgID,
            addLabelIds: [],
            removeLabelIds: [GmailSystemLabel.inbox]
        )
        selectNext(nil)

        let item = SnoozedItem(
            messageId: msgID,
            threadId: email.gmailThreadID,
            accountID: vm.accountID,
            snoozeUntil: date,
            originalLabelIds: email.gmailLabelIDs,
            subject: email.subject,
            senderName: email.sender.name
        )

        let expectedAccountID = vm.accountID
        UndoActionManager.shared.schedule(
            label: "Snoozed",
            onConfirm: { [weak vm] in
                Task { @MainActor [weak vm] in
                    guard let vm, vm.accountID == expectedAccountID else { return }
                    guard AccountStore.shared.accounts.contains(where: { $0.id == expectedAccountID }) else { return }
                    // Archive first; only register in SnoozeStore after a successful archive
                    // so a failed archive doesn't leave the email in both inbox and snoozed list.
                    await vm.archive(msgID)
                    guard vm.error == nil else { return }
                    SnoozeStore.shared.add(item)
                }
            },
            onUndo: { [weak vm] in Task {
                guard let vm, vm.accountID == expectedAccountID else { return }
                guard AccountStore.shared.accounts.contains(where: { $0.id == expectedAccountID }) else { return }
                if let labels = originalLabels {
                    await vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels)
                    vm.lastRestoredMessageID = msgID
                }
            } }
        )
    }

    func unsnoozeEmail(messageId: String, accountID: String) {
        let item = SnoozeStore.shared.items.first { $0.messageId == messageId && $0.accountID == accountID }
        SnoozeStore.shared.remove(messageId: messageId, accountID: accountID)
        Task {
            do {
                try await GmailMessageService.shared.modifyLabels(
                    id: messageId,
                    add: [GmailSystemLabel.inbox],
                    remove: [],
                    accountID: accountID
                )
            } catch {
                if let item { SnoozeStore.shared.add(item) }
                ToastManager.shared.show(message: "Failed to unsnooze", type: .error)
            }
        }
    }

    func printEmail(_ email: Email) async {
        guard let msgID = email.gmailMessageID else { return }
        do {
            let message = try await GmailMessageService.shared.getMessage(id: msgID, accountID: mailboxViewModel.accountID)
            EmailPrintService.shared.printEmail(message: message, email: email)
        } catch {
            ToastManager.shared.show(message: "Print failed: \(error.localizedDescription)", type: .error)
        }
    }

    func emptyTrash(accountID: String, onConfirm: @escaping (Int) -> Void) {
        confirmEmptyFolder(labelID: GmailSystemLabel.trash, accountID: accountID, onConfirm: onConfirm)
    }

    func emptySpam(accountID: String, onConfirm: @escaping (Int) -> Void) {
        confirmEmptyFolder(labelID: GmailSystemLabel.spam, accountID: accountID, onConfirm: onConfirm)
    }

    private func confirmEmptyFolder(labelID: String, accountID: String, onConfirm: @escaping (Int) -> Void) {
        guard !accountID.isEmpty else { return }
        let expectedAccountID = accountID
        Task { [weak self] in
            guard let self else { return }
            var count: Int
            do {
                let label = try await GmailLabelService.shared.getLabel(id: labelID, accountID: accountID)
                count = label.messagesTotal ?? 0
            } catch {
                guard self.mailboxViewModel.accountID == expectedAccountID else { return }
                count = self.mailboxViewModel.emails.count
            }
            guard count > 0 else { return }
            onConfirm(count)
        }
    }

    // MARK: - Bulk undoable action helper

    /// Shared flow for bulk email actions that follow the optimistic-update + undo pattern:
    /// loop to optimistically update labels → clear selection → offline queue OR schedule undo.
    private func performBulkUndoableAction(
        emails: [Email],
        addLabels: [String],
        removeLabels: [String],
        onClear: () -> Void,
        offlineType: OfflineAction.ActionType?,
        offlineToast: String,
        undoLabel: String
    ) async {
        if offlineType == nil, !NetworkMonitor.shared.isConnected {
            ToastManager.shared.show(message: offlineToast, type: .error)
            return
        }
        let vm = mailboxViewModel
        let msgIDs = emails.compactMap(\.gmailMessageID)
        let originalLabelsMap = await vm.updateLabelsInDatabaseBatch(msgIDs, addLabelIds: addLabels, removeLabelIds: removeLabels)
        onClear()
        if let offlineType, !NetworkMonitor.shared.isConnected {
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: offlineType, messageIds: msgIDs, accountID: vm.accountID
            ))
            ToastManager.shared.show(message: offlineToast)
            return
        }
        let expectedAccountID = vm.accountID
        UndoActionManager.shared.schedule(
            label: undoLabel,
            onConfirm: { [weak vm, api] in Task {
                guard let vm, vm.accountID == expectedAccountID else { return }
                guard AccountStore.shared.accounts.contains(where: { $0.id == expectedAccountID }) else { return }
                try? await api.batchModifyLabels(
                    ids: msgIDs, add: addLabels, remove: removeLabels, accountID: expectedAccountID
                )
            } },
            onUndo: { [weak vm] in Task {
                guard let vm, vm.accountID == expectedAccountID else { return }
                guard AccountStore.shared.accounts.contains(where: { $0.id == expectedAccountID }) else { return }
                for (id, labels) in originalLabelsMap {
                    await vm.restoreLabelsInDatabase(id, originalLabelIds: labels)
                }
            } }
        )
    }

    // MARK: - Bulk actions

    func bulkArchive(_ emails: [Email], onClear: () -> Void) async {
        await performBulkUndoableAction(
            emails: emails,
            addLabels: [],
            removeLabels: [GmailSystemLabel.inbox],
            onClear: onClear,
            offlineType: .archive,
            offlineToast: "Archived \(emails.count) emails (will sync when online)",
            undoLabel: "Archived \(emails.count) emails"
        )
    }

    func bulkDelete(_ emails: [Email], onClear: () -> Void) async {
        await performBulkUndoableAction(
            emails: emails,
            addLabels: [GmailSystemLabel.trash],
            removeLabels: [GmailSystemLabel.inbox],
            onClear: onClear,
            offlineType: .trash,
            offlineToast: "Moved \(emails.count) emails to Trash (will sync when online)",
            undoLabel: "Trashed \(emails.count) emails"
        )
    }

    func bulkMarkUnread(_ emails: [Email], onClear: () -> Void) async {
        let vm = mailboxViewModel
        let msgIDs = emails.compactMap(\.gmailMessageID)
        // Save originals for revert via single-transaction batch update
        let originalLabelsMap = await vm.updateLabelsInDatabaseBatch(msgIDs, addLabelIds: [GmailSystemLabel.unread], removeLabelIds: [])
        onClear()
        let accountID = vm.accountID
        let api = self.api
        do {
            try await api.batchModifyLabels(
                ids: msgIDs, add: [GmailSystemLabel.unread], remove: [], accountID: accountID
            )
        } catch {
            // Revert optimistic update
            for (id, labels) in originalLabelsMap {
                await vm.restoreLabelsInDatabase(id, originalLabelIds: labels)
            }
            ToastManager.shared.show(message: "Failed to update read status", type: .error)
        }
    }

    func bulkMarkRead(_ emails: [Email], onClear: () -> Void) async {
        let vm = mailboxViewModel
        let msgIDs = emails.compactMap(\.gmailMessageID)
        // Save originals for revert via single-transaction batch update
        let originalLabelsMap = await vm.updateLabelsInDatabaseBatch(msgIDs, addLabelIds: [], removeLabelIds: [GmailSystemLabel.unread])
        onClear()
        let accountID = vm.accountID
        let api = self.api
        do {
            try await api.batchModifyLabels(
                ids: msgIDs, add: [], remove: [GmailSystemLabel.unread], accountID: accountID
            )
        } catch {
            // Revert optimistic update
            for (id, labels) in originalLabelsMap {
                await vm.restoreLabelsInDatabase(id, originalLabelIds: labels)
            }
            ToastManager.shared.show(message: "Failed to update read status", type: .error)
        }
    }

    func bulkMoveToInbox(_ emails: [Email], selectedFolder: Folder, onClear: () -> Void) async {
        guard NetworkMonitor.shared.isConnected else {
            ToastManager.shared.show(message: "Move to Inbox requires internet connection", type: .error)
            return
        }
        let removeLabels = selectedFolder == .trash ? [GmailSystemLabel.trash] : [String]()
        await performBulkUndoableAction(
            emails: emails,
            addLabels: [GmailSystemLabel.inbox],
            removeLabels: removeLabels,
            onClear: onClear,
            offlineType: nil,
            offlineToast: "",
            undoLabel: "Moved \(emails.count) to Inbox"
        )
    }
}
