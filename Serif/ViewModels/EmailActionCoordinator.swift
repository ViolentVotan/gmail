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

    // MARK: - Single email actions

    func archiveEmail(_ email: Email, selectNext: (Email?) -> Void) {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        let removed = vm.removeOptimistically(msgID)
        let originalLabels = vm.updateLabelsInDatabase(
            msgID,
            addLabelIds: [],
            removeLabelIds: [GmailSystemLabel.inbox]
        )
        selectNext(nil)
        guard NetworkMonitor.shared.isConnected else {
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: .archive, messageIds: [msgID], accountID: vm.accountID
            ))
            ToastManager.shared.show(message: "Archived (will sync when online)")
            return
        }
        UndoActionManager.shared.schedule(
            label: "Archived",
            onConfirm: { Task { await vm.archive(msgID) } },
            onUndo: {
                if let msg = removed { vm.restoreOptimistically(msg) }
                if let labels = originalLabels { vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels) }
            }
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
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        let removed = vm.removeOptimistically(msgID)
        let originalLabels = vm.updateLabelsInDatabase(
            msgID,
            addLabelIds: [GmailSystemLabel.trash],
            removeLabelIds: [GmailSystemLabel.inbox]
        )
        selectNext(nil)
        guard NetworkMonitor.shared.isConnected else {
            OfflineActionQueue.shared.enqueue(OfflineAction(
                actionType: .trash, messageIds: [msgID], accountID: vm.accountID
            ))
            ToastManager.shared.show(message: "Moved to Trash (will sync when online)")
            return
        }
        UndoActionManager.shared.schedule(
            label: "Moved to Trash",
            onConfirm: { Task { await vm.trash(msgID) } },
            onUndo: {
                if let msg = removed { vm.restoreOptimistically(msg) }
                if let labels = originalLabels { vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels) }
            }
        )
    }

    func toggleStarEmail(_ email: Email) {
        guard let msgID = email.gmailMessageID else { return }
        Task { await mailboxViewModel.toggleStar(msgID, isStarred: email.isStarred) }
    }

    func markUnreadEmail(_ email: Email) {
        guard let msgID = email.gmailMessageID else { return }
        Task { await mailboxViewModel.markAsUnread(msgID) }
    }

    func markSpamEmail(_ email: Email, selectNext: @escaping (Email?) -> Void) {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        let removed = vm.removeOptimistically(msgID)
        let originalLabels = vm.updateLabelsInDatabase(
            msgID,
            addLabelIds: [GmailSystemLabel.spam],
            removeLabelIds: [GmailSystemLabel.inbox]
        )
        selectNext(nil)
        UndoActionManager.shared.schedule(
            label: "Marked as Spam",
            onConfirm: { Task { await vm.spam(msgID) } },
            onUndo: {
                if let msg = removed { vm.restoreOptimistically(msg) }
                if let labels = originalLabels { vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels) }
            }
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
        let removed = vm.removeOptimistically(msgID)
        let removeLabels = selectedFolder == .trash ? [GmailSystemLabel.trash] : []
        let originalLabels = vm.updateLabelsInDatabase(
            msgID,
            addLabelIds: [GmailSystemLabel.inbox],
            removeLabelIds: removeLabels
        )
        selectNext(nil)
        if selectedFolder == .trash {
            UndoActionManager.shared.schedule(
                label: "Moved to Inbox",
                onConfirm: { Task { await vm.untrash(msgID) } },
                onUndo: {
                    if let msg = removed { vm.restoreOptimistically(msg) }
                    if let labels = originalLabels { vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels) }
                }
            )
        } else {
            UndoActionManager.shared.schedule(
                label: "Moved to Inbox",
                onConfirm: { Task { await vm.moveToInbox(msgID) } },
                onUndo: {
                    if let msg = removed { vm.restoreOptimistically(msg) }
                    if let labels = originalLabels { vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels) }
                }
            )
        }
    }

    func deletePermanentlyEmail(_ email: Email, selectNext: (Email?) -> Void) {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        let removed = vm.removeOptimistically(msgID)
        // Remove all labels from DB so ValueObservation won't bring it back
        let originalLabels = vm.removeAllLabelsInDatabase(msgID)
        selectNext(nil)
        UndoActionManager.shared.schedule(
            label: "Deleted permanently",
            onConfirm: { Task { await vm.deletePermanently(msgID) } },
            onUndo: {
                if let msg = removed { vm.restoreOptimistically(msg) }
                if let labels = originalLabels { vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels) }
            }
        )
    }

    func markNotSpamEmail(_ email: Email, selectNext: (Email?) -> Void) {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        let removed = vm.removeOptimistically(msgID)
        let originalLabels = vm.updateLabelsInDatabase(
            msgID,
            addLabelIds: [GmailSystemLabel.inbox],
            removeLabelIds: [GmailSystemLabel.spam]
        )
        selectNext(nil)
        UndoActionManager.shared.schedule(
            label: "Moved to Inbox",
            onConfirm: { Task { await vm.unspam(msgID) } },
            onUndo: {
                if let msg = removed { vm.restoreOptimistically(msg) }
                if let labels = originalLabels { vm.restoreLabelsInDatabase(msgID, originalLabelIds: labels) }
            }
        )
    }

    func snoozeEmail(_ email: Email, until date: Date, selectNext: (Email?) -> Void) {
        guard let msgID = email.gmailMessageID else { return }
        let vm = mailboxViewModel
        let removed = vm.removeOptimistically(msgID)
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

        UndoActionManager.shared.schedule(
            label: "Snoozed",
            onConfirm: {
                SnoozeStore.shared.add(item)
                Task { await vm.archive(msgID) }
            },
            onUndo: { if let msg = removed { vm.restoreOptimistically(msg) } }
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
        let removed = msgIDs.compactMap { vm.removeOptimistically($0) }
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
        UndoActionManager.shared.schedule(
            label: "Archived \(msgIDs.count) emails",
            onConfirm: { Task { await withTaskGroup(of: Void.self) { group in for id in msgIDs { group.addTask { await vm.archive(id) } } } } },
            onUndo: {
                for msg in removed { vm.restoreOptimistically(msg) }
                for (id, labels) in originalLabelsMap {
                    vm.restoreLabelsInDatabase(id, originalLabelIds: labels)
                }
            }
        )
    }

    func bulkDelete(_ emails: [Email], onClear: () -> Void) {
        let vm = mailboxViewModel
        let msgIDs = emails.compactMap(\.gmailMessageID)
        let removed = msgIDs.compactMap { vm.removeOptimistically($0) }
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
        UndoActionManager.shared.schedule(
            label: "Trashed \(msgIDs.count) emails",
            onConfirm: { Task { await withTaskGroup(of: Void.self) { group in for id in msgIDs { group.addTask { await vm.trash(id) } } } } },
            onUndo: {
                for msg in removed { vm.restoreOptimistically(msg) }
                for (id, labels) in originalLabelsMap {
                    vm.restoreLabelsInDatabase(id, originalLabelIds: labels)
                }
            }
        )
    }

    func bulkMarkUnread(_ emails: [Email], onClear: () -> Void) {
        let msgIDs = emails.compactMap(\.gmailMessageID)
        onClear()
        let vm = mailboxViewModel
        Task { await withTaskGroup(of: Void.self) { group in for id in msgIDs { group.addTask { await vm.markAsUnread(id) } } } }
    }

    func bulkMarkRead(_ emails: [Email], onClear: () -> Void) {
        let msgs = emails.compactMap { e -> GmailMessage? in
            guard let msgID = e.gmailMessageID else { return nil }
            return mailboxViewModel.messages.first { $0.id == msgID }
        }
        onClear()
        let vm = mailboxViewModel
        Task { await withTaskGroup(of: Void.self) { group in for msg in msgs { group.addTask { await vm.markAsRead(msg) } } } }
    }

    func bulkMoveToInbox(_ emails: [Email], selectedFolder: Folder, onClear: () -> Void) {
        let vm = mailboxViewModel
        let msgIDs = emails.compactMap(\.gmailMessageID)
        let removed = msgIDs.compactMap { vm.removeOptimistically($0) }
        let removeLabels = selectedFolder == .trash ? [GmailSystemLabel.trash] : [String]()
        var originalLabelsMap: [String: [String]] = [:]
        for id in msgIDs {
            if let labels = vm.updateLabelsInDatabase(id, addLabelIds: [GmailSystemLabel.inbox], removeLabelIds: removeLabels) {
                originalLabelsMap[id] = labels
            }
        }
        onClear()
        if selectedFolder == .trash {
            UndoActionManager.shared.schedule(
                label: "Moved \(msgIDs.count) to Inbox",
                onConfirm: { Task { await withTaskGroup(of: Void.self) { group in for id in msgIDs { group.addTask { await vm.untrash(id) } } } } },
                onUndo: {
                    for msg in removed { vm.restoreOptimistically(msg) }
                    for (id, labels) in originalLabelsMap {
                        vm.restoreLabelsInDatabase(id, originalLabelIds: labels)
                    }
                }
            )
        } else {
            UndoActionManager.shared.schedule(
                label: "Moved \(msgIDs.count) to Inbox",
                onConfirm: { Task { await withTaskGroup(of: Void.self) { group in for id in msgIDs { group.addTask { await vm.moveToInbox(id) } } } } },
                onUndo: {
                    for msg in removed { vm.restoreOptimistically(msg) }
                    for (id, labels) in originalLabelsMap {
                        vm.restoreLabelsInDatabase(id, originalLabelIds: labels)
                    }
                }
            )
        }
    }
}
