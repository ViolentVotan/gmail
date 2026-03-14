import SwiftUI

struct DetailPaneView: View {
    let selectedEmail: Email?
    let selectedEmailIDs: Set<String>
    let selectedFolder: Folder
    let displayedEmails: [Email]

    let coordinator: AppCoordinator

    // MARK: - Convenience Accessors

    private var actionCoordinator: EmailActionCoordinator { coordinator.actionCoordinator }
    private var mailboxViewModel: MailboxViewModel { coordinator.mailboxViewModel }
    private var mailStore: MailStore { coordinator.mailStore }
    private var accountID: String { coordinator.accountID }
    private var fromAddress: String { coordinator.fromAddress }
    private var composeMode: ComposeMode { coordinator.composeMode }
    private var signatureForNew: String { coordinator.signatureForNew }
    private var signatureForReply: String { coordinator.signatureForReply }
    private var panelCoordinator: PanelCoordinator { coordinator.panelCoordinator }
    private var attachmentIndexer: AttachmentIndexer? { coordinator.attachmentIndexer }

    private var isMultiSelect: Bool { selectedEmailIDs.count > 1 }

    private var isEditingDraft: Bool {
        guard let email = selectedEmail else { return false }
        return email.isDraft
    }

    private var selectedEmails: [Email] {
        displayedEmails.filter { selectedEmailIDs.contains($0.id.uuidString) }
    }

    var body: some View {
        Group {
            if isMultiSelect {
                bulkActionView
            } else if isEditingDraft, let draftId = selectedEmail?.id {
                composeView(draftId: draftId)
            } else if let email = selectedEmail {
                emailDetailView(email: email)
            } else {
                emptyState
            }
        }
        .navigationSplitViewColumnWidth(min: 400, ideal: 600)
    }

    // MARK: - Bulk Actions

    private var bulkActionView: some View {
        BulkActionBarView(
            count: selectedEmailIDs.count,
            selectedFolder: selectedFolder,
            onArchive:     { actionCoordinator.bulkArchive(selectedEmails, onClear: { coordinator.clearSelection() }) },
            onDelete:      { actionCoordinator.bulkDelete(selectedEmails, onClear: { coordinator.clearSelection() }) },
            onMarkUnread:  { actionCoordinator.bulkMarkUnread(selectedEmails, onClear: { coordinator.deselectAll() }) },
            onMarkRead:    { actionCoordinator.bulkMarkRead(selectedEmails, onClear: { coordinator.deselectAll() }) },
            onToggleStar:  { for e in selectedEmails { actionCoordinator.toggleStarEmail(e) } },
            onMoveToInbox: { actionCoordinator.bulkMoveToInbox(selectedEmails, selectedFolder: selectedFolder, onClear: { coordinator.clearSelection() }) },
            onDeselectAll: { coordinator.deselectAll() }
        )
    }

    // MARK: - Compose

    private func composeView(draftId: UUID) -> some View {
        ComposeView(
            mailStore: mailStore,
            draftId: draftId,
            accountID: accountID,
            fromAddress: fromAddress,
            mode: composeMode,
            sendAsAliases: mailboxViewModel.sendAsAliases,
            signatureForNew: signatureForNew,
            signatureForReply: signatureForReply,
            contacts: coordinator.contacts,
            onDiscard: { coordinator.discardDraft(id: draftId) },
            onOpenLink: { url in panelCoordinator.openInAppBrowser(url: url) }
        )
        .id(draftId)
        .onAppear { coordinator.loadContacts() }
    }

    // MARK: - Email Detail

    private func emailDetailView(email: Email) -> some View {
        var actions = EmailDetailActions()
        actions.onArchive = selectedFolder == .archive ? nil : { actionCoordinator.archiveEmail(email, selectNext: { coordinator.selectNext($0) }) }
        actions.onDelete = selectedFolder == .trash ? nil : { actionCoordinator.deleteEmail(email, selectNext: { coordinator.selectNext($0) }) }
        actions.onMoveToInbox = selectedFolder == .archive || selectedFolder == .trash
            ? { actionCoordinator.moveToInboxEmail(email, selectedFolder: selectedFolder, selectNext: { coordinator.selectNext($0) }) } : nil
        actions.onDeletePermanently = selectedFolder == .trash
            ? { actionCoordinator.deletePermanentlyEmail(email, selectNext: { coordinator.selectNext($0) }) } : nil
        actions.onMarkNotSpam = selectedFolder == .spam
            ? { actionCoordinator.markNotSpamEmail(email, selectNext: { coordinator.selectNext($0) }) } : nil
        actions.onToggleStar = { isCurrentlyStarred in
            guard let msgID = email.gmailMessageID else { return }
            Task { await mailboxViewModel.toggleStar(msgID, isStarred: isCurrentlyStarred) }
        }
        actions.onMarkUnread = { actionCoordinator.markUnreadEmail(email) }
        actions.onSnooze = { date in actionCoordinator.snoozeEmail(email, until: date, selectNext: { coordinator.selectNext($0) }) }
        actions.onAddLabel = { labelID in
            guard let msgID = email.gmailMessageID else { return }
            Task { await mailboxViewModel.addLabel(labelID, to: msgID) }
        }
        actions.onRemoveLabel = { labelID in
            guard let msgID = email.gmailMessageID else { return }
            Task { await mailboxViewModel.removeLabel(labelID, from: msgID) }
        }
        actions.onReply = { mode in coordinator.startCompose(mode: mode) }
        actions.onReplyAll = { mode in coordinator.startCompose(mode: mode) }
        actions.onForward = { mode in coordinator.startCompose(mode: mode) }
        actions.onCreateAndAddLabel = { name, completion in
            guard let msgID = email.gmailMessageID else { completion(nil); return }
            Task {
                let labelID = await mailboxViewModel.createAndAddLabel(name: name, to: msgID)
                completion(labelID)
            }
        }
        actions.onPreviewAttachment = { data, name, fileType in
            panelCoordinator.previewAttachment(data: data, name: name, fileType: fileType)
        }
        actions.onShowOriginal = { msg, acctID in
            panelCoordinator.showOriginalMessage(message: msg, accountID: acctID)
        }
        actions.onDownloadMessage = { msg, acctID in
            panelCoordinator.downloadMessage(message: msg, accountID: acctID)
        }
        actions.onUnsubscribe = { url, oneClick, msgID in
            await actionCoordinator.unsubscribe(url: url, oneClick: oneClick, messageID: msgID, accountID: accountID)
        }
        actions.onPrint = { msg, email in
            actionCoordinator.printEmail(message: msg, email: email)
        }
        actions.checkUnsubscribed = { msgID in
            actionCoordinator.isUnsubscribed(messageID: msgID, accountID: accountID)
        }
        actions.extractBodyUnsubscribeURL = { html in
            actionCoordinator.extractBodyUnsubscribeURL(from: html)
        }
        actions.onOpenLink = { url in panelCoordinator.openInAppBrowser(url: url) }
        actions.onMessagesRead = { messageIDs in mailboxViewModel.applyReadLocally(messageIDs) }
        actions.onLoadDraft = { draftID, acctID in
            try await actionCoordinator.loadDraft(id: draftID, accountID: acctID)
        }

        return EmailDetailView(
            email: email,
            accountID: accountID,
            mailStore: mailStore,
            actions: actions,
            attachmentIndexer: attachmentIndexer,
            allLabels: mailboxViewModel.labels,
            fromAddress: fromAddress,
            mailDatabase: coordinator.mailDatabase
        )
        .id(email.id)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            emptyStateTitle,
            systemImage: emptyStateIcon,
            description: Text(emptyStateDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateIcon: String {
        switch selectedFolder {
        case .drafts:        return "doc.text"
        case .sent:          return "paperplane"
        case .trash:         return "trash"
        case .spam:          return "exclamationmark.shield"
        case .starred:       return "star"
        case .archive:       return "archivebox"
        case .attachments:   return "paperclip"
        case .subscriptions: return "newspaper"
        default:             return "envelope.open"
        }
    }

    private var emptyStateTitle: String {
        switch selectedFolder {
        case .drafts:        return "No Draft Selected"
        case .sent:          return "No Email Selected"
        case .starred:       return "No Email Selected"
        case .archive:       return "No Email Selected"
        case .attachments:   return "No Email Selected"
        case .subscriptions: return "No Subscription Selected"
        default:             return "No Email Selected"
        }
    }

    private var emptyStateDescription: String {
        switch selectedFolder {
        case .drafts:        return "Select a draft to edit"
        case .sent:          return "Select a sent email to view"
        case .starred:       return "Select a starred email to read"
        case .archive:       return "Select an archived email to read"
        case .attachments:   return "Select an email to view attachments"
        case .subscriptions: return "Select a subscription to view"
        default:             return "Select an email to read"
        }
    }
}
