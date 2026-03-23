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
        apiAction: @escaping (String) async throws -> Void
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
            await OfflineActionQueue.shared.enqueue(OfflineAction(
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
                do {
                    try await apiAction(msgID)
                } catch {
                    // API failed after undo timer expired — enqueue for retry
                    if let offlineType {
                        let action = OfflineAction(
                            actionType: offlineType,
                            messageIds: [msgID],
                            accountID: expectedAccountID
                        )
                        await OfflineActionQueue.shared.enqueue(action)
                    }
                }
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

    /// Handles the offline guard + enqueue + optimistic DB update + toast pattern.
    /// Returns `true` if the caller should proceed with the online API call, `false` if offline handling was applied.
    @discardableResult
    private func performOptimisticLabelAction(
        messageID: String,
        addLabelIds: [String],
        removeLabelIds: [String],
        offlineActionType: OfflineAction.ActionType,
        toastMessage: String
    ) async -> Bool {
        guard NetworkMonitor.shared.isConnected else {
            let vm = mailboxViewModel
            await OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: offlineActionType, messageIds: [messageID], accountID: vm.accountID
            ))
            _ = await vm.updateLabelsInDatabase(messageID, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
            ToastManager.shared.show(message: toastMessage)
            return false
        }
        return true
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
            apiAction: { [api, mailboxViewModel] msgID in try await api.archiveMessage(id: msgID, accountID: mailboxViewModel.accountID) }
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
            apiAction: { [api, mailboxViewModel] msgID in try await api.trashMessage(id: msgID, accountID: mailboxViewModel.accountID) }
        )
    }

    func toggleStarEmail(_ email: Email) async {
        guard let msgID = email.gmailMessageID else { return }
        let adding = email.isStarred ? [] : [GmailSystemLabel.starred]
        let removing = email.isStarred ? [GmailSystemLabel.starred] : [String]()
        guard await performOptimisticLabelAction(
            messageID: msgID,
            addLabelIds: adding,
            removeLabelIds: removing,
            offlineActionType: email.isStarred ? .unstar : .star,
            toastMessage: email.isStarred ? "Unstarred (will sync when online)" : "Starred (will sync when online)"
        ) else { return }
        await mailboxViewModel.toggleStar(msgID, isStarred: email.isStarred)
    }

    func markReadEmail(_ email: Email) async {
        guard let msgID = email.gmailMessageID else { return }
        guard await performOptimisticLabelAction(
            messageID: msgID,
            addLabelIds: [],
            removeLabelIds: [GmailSystemLabel.unread],
            offlineActionType: .markRead,
            toastMessage: "Marked read (will sync when online)"
        ) else { return }
        await mailboxViewModel.markAsRead(msgID)
    }

    func markUnreadEmail(_ email: Email) async {
        guard let msgID = email.gmailMessageID else { return }
        guard await performOptimisticLabelAction(
            messageID: msgID,
            addLabelIds: [GmailSystemLabel.unread],
            removeLabelIds: [],
            offlineActionType: .markUnread,
            toastMessage: "Marked unread (will sync when online)"
        ) else { return }
        await mailboxViewModel.markAsUnread(msgID)
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
            apiAction: { [api, mailboxViewModel] msgID in try await api.spamMessage(id: msgID, accountID: mailboxViewModel.accountID) }
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
        let apiAction: (String) async throws -> Void = selectedFolder == .trash
            ? { [api, mailboxViewModel] msgID in _ = try await api.untrashMessage(id: msgID, accountID: mailboxViewModel.accountID) }
            : { [api, mailboxViewModel] msgID in
                try await api.modifyLabels(
                    id: msgID,
                    add: [GmailSystemLabel.inbox],
                    remove: [],
                    accountID: mailboxViewModel.accountID
                )
            }
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
            apiAction: { [api, mailboxViewModel] msgID in
                try await api.modifyLabels(
                    id: msgID,
                    add: [GmailSystemLabel.inbox],
                    remove: [GmailSystemLabel.spam],
                    accountID: mailboxViewModel.accountID
                )
            }
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
                    let success = await vm.archive(msgID)
                    guard success else { return }
                    await SnoozeStore.shared.add(item)
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
        Task {
            await SnoozeStore.shared.remove(messageId: messageId, accountID: accountID)
            do {
                try await GmailMessageService.shared.modifyLabels(
                    id: messageId,
                    add: [GmailSystemLabel.inbox],
                    remove: [],
                    accountID: accountID
                )
            } catch {
                if let item { await SnoozeStore.shared.add(item) }
                ToastManager.shared.show(message: "Failed to unsnooze", type: .error)
            }
        }
    }

    /// Adds a user label to a message. Delegates to MailboxViewModel which handles
    /// optimistic DB update, offline queue, and API call.
    func addLabelToEmail(_ labelID: String, to messageID: String) async {
        await mailboxViewModel.addLabel(labelID, to: messageID)
    }

    /// Removes a user label from a message. Delegates to MailboxViewModel which handles
    /// optimistic DB update, offline queue, and API call.
    func removeLabelFromEmail(_ labelID: String, from messageID: String) async {
        await mailboxViewModel.removeLabel(labelID, from: messageID)
    }

    /// Creates a new label and adds it to the message.
    @discardableResult
    func createAndAddLabelToEmail(name: String, to messageID: String) async -> String? {
        await mailboxViewModel.createAndAddLabel(name: name, to: messageID)
    }

    /// Empties the Trash folder (permanent deletion of all trashed messages).
    func emptyTrashFolder() async {
        await mailboxViewModel.emptyTrash()
    }

    /// Empties the Spam folder (permanent deletion of all spam messages).
    func emptySpamFolder() async {
        await mailboxViewModel.emptySpam()
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
            await OfflineActionQueue.shared.enqueue(OfflineAction(
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
                do {
                    try await api.batchModifyLabels(
                        ids: msgIDs, add: addLabels, remove: removeLabels, accountID: expectedAccountID
                    )
                } catch {
                    // API failed after undo timer expired — enqueue for offline retry
                    if let offlineType {
                        let action = OfflineAction(
                            actionType: offlineType,
                            messageIds: msgIDs,
                            accountID: expectedAccountID
                        )
                        await OfflineActionQueue.shared.enqueue(action)
                    }
                }
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
        await performBulkLabelUpdate(
            emails: emails,
            addLabelIDs: [GmailSystemLabel.unread],
            removeLabelIDs: [],
            onClear: onClear
        )
    }

    func bulkMarkRead(_ emails: [Email], onClear: () -> Void) async {
        await performBulkLabelUpdate(
            emails: emails,
            addLabelIDs: [],
            removeLabelIDs: [GmailSystemLabel.unread],
            onClear: onClear
        )
    }

    /// Optimistically updates labels in the DB, calls the Gmail API, and reverts on failure.
    /// Uses `batchModifyLabels` for multiple messages (more efficient) and `modifyLabels` for a single message.
    private func performBulkLabelUpdate(
        emails: [Email],
        addLabelIDs: [String],
        removeLabelIDs: [String],
        onClear: () -> Void
    ) async {
        let vm = mailboxViewModel
        let msgIDs = emails.compactMap(\.gmailMessageID)
        guard !msgIDs.isEmpty else { return }
        let originalLabelsMap = await vm.updateLabelsInDatabaseBatch(msgIDs, addLabelIds: addLabelIDs, removeLabelIds: removeLabelIDs)
        onClear()
        let accountID = vm.accountID
        do {
            if msgIDs.count == 1 {
                try await api.modifyLabels(id: msgIDs[0], add: addLabelIDs, remove: removeLabelIDs, accountID: accountID)
            } else {
                try await api.batchModifyLabels(ids: msgIDs, add: addLabelIDs, remove: removeLabelIDs, accountID: accountID)
            }
        } catch {
            for (id, labels) in originalLabelsMap {
                await vm.restoreLabelsInDatabase(id, originalLabelIds: labels)
            }
            ToastManager.shared.show(message: "Failed to update labels", type: .error)
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
