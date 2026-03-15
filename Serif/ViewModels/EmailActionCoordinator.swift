import SwiftUI

@Observable
@MainActor
final class EmailActionCoordinator {
    let mailboxViewModel: MailboxViewModel
    let mailStore: MailStore

    init(mailboxViewModel: MailboxViewModel, mailStore: MailStore) {
        self.mailboxViewModel = mailboxViewModel
        self.mailStore = mailStore
    }

    // MARK: - Network / Offline state

    var isConnected: Bool { NetworkMonitor.shared.isConnected }
    var pendingOfflineActionCount: Int { OfflineActionQueue.shared.pendingCount }

    // MARK: - Undoable action helper

    /// Shared flow for single-email actions that follow the optimistic-update + undo pattern:
    /// guard msgID → optimistic DB update → selectNext → offline queue OR schedule undo.
    private func performUndoableAction(
        email: Email,
        label: String,
        addLabels: [String],
        removeLabels: [String],
        selectNext: (Email?) -> Void,
        offlineType: OfflineAction.ActionType,
        offlineToast: String,
        apiAction: @escaping (String) async -> Void
    ) {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        let originalLabels = vm.updateLabelsInDatabase(msgID, addLabelIds: addLabels, removeLabelIds: removeLabels)
        selectNext(nil)
        guard NetworkMonitor.shared.isConnected else {
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
                await apiAction(msgID)
            } },
            onUndo: { [weak vm] in
                guard let vm, vm.accountID == expectedAccountID else { return }
                if let labels = originalLabels {
                    vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels)
                    vm.lastRestoredMessageID = msgID
                }
            }
        )
    }

    // MARK: - Single email actions

    func archiveEmail(_ email: Email, selectNext: (Email?) -> Void) {
        performUndoableAction(
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

    func deleteEmail(_ email: Email, selectNext: (Email?) -> Void) {
        // Draft-specific path: delete from mailStore directly
        if email.isDraft {
            if let gid = email.gmailDraftID {
                let accountID = mailboxViewModel.accountID
                Task { try? await GmailDraftService.shared.deleteDraft(draftID: gid, accountID: accountID) }
            }
            mailStore.deleteDraft(id: email.id)
            selectNext(nil)
            return
        }
        performUndoableAction(
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

    func toggleStarEmail(_ email: Email) {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        guard NetworkMonitor.shared.isConnected else {
            let actionType: OfflineAction.ActionType = email.isStarred ? .unstar : .star
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: actionType, messageIds: [msgID], accountID: vm.accountID
            ))
            // Optimistic DB update so UI reflects the change immediately
            _ = vm.updateLabelsInDatabase(
                msgID,
                addLabelIds: email.isStarred ? [] : [GmailSystemLabel.starred],
                removeLabelIds: email.isStarred ? [GmailSystemLabel.starred] : []
            )
            ToastManager.shared.show(message: email.isStarred ? "Unstarred (will sync when online)" : "Starred (will sync when online)")
            return
        }
        Task { await vm.toggleStar(msgID, isStarred: email.isStarred) }
    }

    func markUnreadEmail(_ email: Email) {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        guard NetworkMonitor.shared.isConnected else {
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: .markUnread, messageIds: [msgID], accountID: vm.accountID
            ))
            // Optimistic DB update
            _ = vm.updateLabelsInDatabase(msgID, addLabelIds: [GmailSystemLabel.unread], removeLabelIds: [])
            ToastManager.shared.show(message: "Marked unread (will sync when online)")
            return
        }
        Task { await vm.markAsUnread(msgID) }
    }

    func markSpamEmail(_ email: Email, selectNext: @escaping (Email?) -> Void) {
        performUndoableAction(
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

    // MARK: - Print

    func printEmail(message: GmailMessage, email: Email) {
        EmailPrintService.shared.printEmail(message: message, email: email)
    }

    func moveToInboxEmail(_ email: Email, selectedFolder: Folder, selectNext: (Email?) -> Void) {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        guard NetworkMonitor.shared.isConnected else {
            ToastManager.shared.show(message: "Move to Inbox requires internet connection", type: .error)
            return
        }
        let removeLabels = selectedFolder == .trash ? [GmailSystemLabel.trash] : [String]()
        let originalLabels = vm.updateLabelsInDatabase(
            msgID,
            addLabelIds: [GmailSystemLabel.inbox],
            removeLabelIds: removeLabels
        )
        selectNext(nil)
        let expectedAccountID = vm.accountID
        if selectedFolder == .trash {
            UndoActionManager.shared.schedule(
                label: "Moved to Inbox",
                onConfirm: { [weak vm] in Task {
                    guard let vm, vm.accountID == expectedAccountID else { return }
                    await vm.untrash(msgID)
                } },
                onUndo: { [weak vm] in
                    guard let vm, vm.accountID == expectedAccountID else { return }
                    if let labels = originalLabels {
                        vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels)
                        vm.lastRestoredMessageID = msgID
                    }
                }
            )
        } else {
            UndoActionManager.shared.schedule(
                label: "Moved to Inbox",
                onConfirm: { [weak vm] in Task {
                    guard let vm, vm.accountID == expectedAccountID else { return }
                    await vm.moveToInbox(msgID)
                } },
                onUndo: { [weak vm] in
                    guard let vm, vm.accountID == expectedAccountID else { return }
                    if let labels = originalLabels {
                        vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels)
                        vm.lastRestoredMessageID = msgID
                    }
                }
            )
        }
    }

    func deletePermanentlyEmail(_ email: Email, selectNext: (Email?) -> Void) {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        guard NetworkMonitor.shared.isConnected else {
            ToastManager.shared.show(message: "Permanent delete requires internet connection", type: .error)
            return
        }
        // Remove all labels from DB so ValueObservation won't bring it back
        let originalLabels = vm.removeAllLabelsInDatabase(msgID)
        selectNext(nil)
        let expectedAccountID = vm.accountID
        UndoActionManager.shared.schedule(
            label: "Deleted permanently",
            onConfirm: { [weak vm] in Task {
                guard let vm, vm.accountID == expectedAccountID else { return }
                await vm.deletePermanently(msgID)
            } },
            onUndo: { [weak vm] in
                guard let vm, vm.accountID == expectedAccountID else { return }
                if let labels = originalLabels {
                    vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels)
                    vm.lastRestoredMessageID = msgID
                }
            }
        )
    }

    func markNotSpamEmail(_ email: Email, selectNext: (Email?) -> Void) {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        guard NetworkMonitor.shared.isConnected else {
            ToastManager.shared.show(message: "Not Spam requires internet connection", type: .error)
            return
        }
        let originalLabels = vm.updateLabelsInDatabase(
            msgID,
            addLabelIds: [GmailSystemLabel.inbox],
            removeLabelIds: [GmailSystemLabel.spam]
        )
        selectNext(nil)
        let expectedAccountID = vm.accountID
        UndoActionManager.shared.schedule(
            label: "Moved to Inbox",
            onConfirm: { [weak vm] in Task {
                guard let vm, vm.accountID == expectedAccountID else { return }
                await vm.unspam(msgID)
            } },
            onUndo: { [weak vm] in
                guard let vm, vm.accountID == expectedAccountID else { return }
                if let labels = originalLabels {
                    vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels)
                    vm.lastRestoredMessageID = msgID
                }
            }
        )
    }

    func snoozeEmail(_ email: Email, until date: Date, selectNext: (Email?) -> Void) {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        guard NetworkMonitor.shared.isConnected else {
            ToastManager.shared.show(message: "Snooze requires internet connection", type: .error)
            return
        }
        // Optimistic DB write: remove from inbox so ValueObservation hides it
        let originalLabels = vm.updateLabelsInDatabase(
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
                guard let vm, vm.accountID == expectedAccountID else { return }
                SnoozeStore.shared.add(item)
                Task { await vm.archive(msgID) }
            },
            onUndo: { [weak vm] in
                guard let vm, vm.accountID == expectedAccountID else { return }
                if let labels = originalLabels {
                    vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels)
                    vm.lastRestoredMessageID = msgID
                }
            }
        )
    }

    func unsnoozeEmail(messageId: String, accountID: String) {
        SnoozeStore.shared.remove(messageId: messageId, accountID: accountID)
        Task {
            try? await GmailMessageService.shared.modifyLabels(
                id: messageId,
                add: [GmailSystemLabel.inbox],
                remove: [],
                accountID: accountID
            )
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
        Task {
            var count: Int
            do {
                let label = try await GmailLabelService.shared.getLabel(id: labelID, accountID: accountID)
                count = label.messagesTotal ?? 0
            } catch {
                count = mailboxViewModel.emails.count
            }
            guard count > 0 else { return }
            onConfirm(count)
        }
    }

    // MARK: - Bulk actions

    func bulkArchive(_ emails: [Email], onClear: () -> Void) {
        let vm = mailboxViewModel
        let msgIDs = emails.compactMap(\.gmailMessageID)
        var originalLabelsMap: [String: [String]] = [:]
        for id in msgIDs {
            if let labels = vm.updateLabelsInDatabase(id, addLabelIds: [], removeLabelIds: [GmailSystemLabel.inbox]) {
                originalLabelsMap[id] = labels
            }
        }
        onClear()
        guard NetworkMonitor.shared.isConnected else {
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: .archive, messageIds: msgIDs, accountID: vm.accountID
            ))
            ToastManager.shared.show(message: "Archived \(msgIDs.count) emails (will sync when online)")
            return
        }
        let expectedAccountID = vm.accountID
        UndoActionManager.shared.schedule(
            label: "Archived \(msgIDs.count) emails",
            onConfirm: { [weak vm] in Task {
                guard let vm, vm.accountID == expectedAccountID else { return }
                try? await GmailMessageService.shared.batchModifyLabels(
                    ids: msgIDs, add: [], remove: [GmailSystemLabel.inbox], accountID: expectedAccountID
                )
            } },
            onUndo: { [weak vm] in
                guard let vm, vm.accountID == expectedAccountID else { return }
                for (id, labels) in originalLabelsMap {
                    vm.restoreLabelsInDatabase(id, originalLabelIds: labels)
                }
            }
        )
    }

    func bulkDelete(_ emails: [Email], onClear: () -> Void) {
        let vm = mailboxViewModel
        let msgIDs = emails.compactMap(\.gmailMessageID)
        var originalLabelsMap: [String: [String]] = [:]
        for id in msgIDs {
            if let labels = vm.updateLabelsInDatabase(id, addLabelIds: [GmailSystemLabel.trash], removeLabelIds: [GmailSystemLabel.inbox]) {
                originalLabelsMap[id] = labels
            }
        }
        onClear()
        guard NetworkMonitor.shared.isConnected else {
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: .trash, messageIds: msgIDs, accountID: vm.accountID
            ))
            ToastManager.shared.show(message: "Moved \(msgIDs.count) emails to Trash (will sync when online)")
            return
        }
        let expectedAccountID = vm.accountID
        UndoActionManager.shared.schedule(
            label: "Trashed \(msgIDs.count) emails",
            onConfirm: { [weak vm] in Task {
                guard let vm, vm.accountID == expectedAccountID else { return }
                try? await GmailMessageService.shared.batchModifyLabels(
                    ids: msgIDs, add: [GmailSystemLabel.trash], remove: [GmailSystemLabel.inbox], accountID: expectedAccountID
                )
            } },
            onUndo: { [weak vm] in
                guard let vm, vm.accountID == expectedAccountID else { return }
                for (id, labels) in originalLabelsMap {
                    vm.restoreLabelsInDatabase(id, originalLabelIds: labels)
                }
            }
        )
    }

    func bulkMarkUnread(_ emails: [Email], onClear: () -> Void) {
        let msgIDs = emails.compactMap(\.gmailMessageID)
        onClear()
        let accountID = mailboxViewModel.accountID
        Task {
            try? await GmailMessageService.shared.batchModifyLabels(
                ids: msgIDs, add: [GmailSystemLabel.unread], remove: [], accountID: accountID
            )
        }
    }

    func bulkMarkRead(_ emails: [Email], onClear: () -> Void) {
        let msgIDs = emails.compactMap(\.gmailMessageID)
        onClear()
        let vm = mailboxViewModel
        vm.applyReadLocally(msgIDs)
        let accountID = vm.accountID
        Task {
            try? await GmailMessageService.shared.batchModifyLabels(
                ids: msgIDs, add: [], remove: [GmailSystemLabel.unread], accountID: accountID
            )
        }
    }

    func bulkMoveToInbox(_ emails: [Email], selectedFolder: Folder, onClear: () -> Void) {
        let vm = mailboxViewModel
        let msgIDs = emails.compactMap(\.gmailMessageID)
        let removeLabels = selectedFolder == .trash ? [GmailSystemLabel.trash] : [String]()
        var originalLabelsMap: [String: [String]] = [:]
        for id in msgIDs {
            if let labels = vm.updateLabelsInDatabase(id, addLabelIds: [GmailSystemLabel.inbox], removeLabelIds: removeLabels) {
                originalLabelsMap[id] = labels
            }
        }
        onClear()
        let expectedAccountID = vm.accountID
        UndoActionManager.shared.schedule(
            label: "Moved \(msgIDs.count) to Inbox",
            onConfirm: { [weak vm] in Task {
                guard let vm, vm.accountID == expectedAccountID else { return }
                try? await GmailMessageService.shared.batchModifyLabels(
                    ids: msgIDs, add: [GmailSystemLabel.inbox], remove: removeLabels, accountID: expectedAccountID
                )
            } },
            onUndo: { [weak vm] in
                guard let vm, vm.accountID == expectedAccountID else { return }
                for (id, labels) in originalLabelsMap {
                    vm.restoreLabelsInDatabase(id, originalLabelIds: labels)
                }
            }
        )
    }
}
