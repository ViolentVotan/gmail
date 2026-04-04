import SwiftUI

// MARK: - Bulk Action Detail View

/// Focused detail pane view for multi-selection bulk actions.
/// Only accepts the parameters needed for bulk operations.
struct BulkActionDetailView: View {
    let selectedEmailIDs: Set<String>
    let selectedFolder: Folder
    let selectedEmails: [Email]
    let actionCoordinator: EmailActionCoordinator
    let clearSelection: () -> Void
    let deselectAll: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BulkActionBarView(
            count: selectedEmailIDs.count,
            selectedFolder: selectedFolder,
            emails: selectedEmails,
            onArchive:     { Task { await actionCoordinator.bulkArchive(selectedEmails, onClear: clearSelection) } },
            onDelete:      { Task { await actionCoordinator.bulkDelete(selectedEmails, onClear: clearSelection) } },
            onMarkUnread:  { Task { await actionCoordinator.bulkMarkUnread(selectedEmails, onClear: deselectAll) } },
            onMarkRead:    { Task { await actionCoordinator.bulkMarkRead(selectedEmails, onClear: deselectAll) } },
            onToggleStar:  { Task { for e in selectedEmails { await actionCoordinator.toggleStarEmail(e) } } },
            onMoveToInbox: { Task { await actionCoordinator.bulkMoveToInbox(selectedEmails, selectedFolder: selectedFolder, onClear: clearSelection) } },
            onDeselectAll: deselectAll
        )
        .transition(.opacity.combined(with: .scale(scale: ScaleToken.enterFrom)))
        .animation(reduceMotion ? nil : VikAnimation.contentSwitch, value: selectedEmailIDs.count > 1)
        .navigationSplitViewColumnWidth(min: 500, ideal: 700)
    }
}

// MARK: - Compose Detail View

/// Focused detail pane view for draft editing / compose mode.
/// Only accepts the parameters needed for composing emails.
struct ComposeDetailView: View {
    let draftId: UUID
    let mailStore: MailStore
    let accountID: String
    let fromAddress: String
    let composeMode: ComposeMode
    let sendAsAliases: [GmailSendAs]
    let signatureForNew: String
    let signatureForReply: String
    let panelCoordinator: PanelCoordinator
    let contacts: [StoredContact]
    let discardDraft: (UUID) -> Void

    var body: some View {
        ComposeView(
            mailStore: mailStore,
            draftId: draftId,
            accountID: accountID,
            fromAddress: fromAddress,
            mode: composeMode,
            sendAsAliases: sendAsAliases,
            signatureForNew: signatureForNew,
            signatureForReply: signatureForReply,
            contacts: contacts,
            onDiscard: { discardDraft(draftId) },
            onOpenLink: { url in panelCoordinator.openInBrowser(url: url) }
        )
        .id(draftId)
        .navigationSplitViewColumnWidth(min: 500, ideal: 700)
    }
}

// MARK: - Email Read Detail View

/// Focused detail pane view for reading a single email.
/// Only accepts the parameters needed for email detail display and actions.
struct EmailReadDetailView: View {
    let email: Email
    let selectedFolder: Folder
    let actionCoordinator: EmailActionCoordinator
    let mailboxViewModel: MailboxViewModel
    let allLabels: [GmailLabel]
    let mailStore: MailStore
    let accountID: String
    let fromAddress: String
    let panelCoordinator: PanelCoordinator
    let attachmentIndexer: AttachmentIndexer?
    let contacts: [StoredContact]
    let mailDatabase: MailDatabase?
    let selectionDirection: Edge
    let selectNext: (Email?) -> Void
    let startCompose: (ComposeMode) -> Void
    let navigatePrevious: () -> Void
    let navigateNext: () -> Void
    var switchToCalendar: ((CalendarEvent) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Resolves the best send-as alias for the given email, falling back to the primary account address.
    /// For outgoing folders (Sent), recipients are outbound contacts — no alias will match, so this
    /// safely falls back to the primary address.
    private func resolvedFromAddress(for email: Email) -> String {
        mailboxViewModel.sendAsAliases.bestAlias(
            toRecipients: email.recipients.map(\.email),
            ccRecipients: email.cc.map(\.email)
        ) ?? fromAddress
    }

    private func softDirectionalTransition(from edge: Edge) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let yOffset: CGFloat = edge == .bottom ? OffsetToken.small : -OffsetToken.small
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: yOffset)),
            removal: .opacity.combined(with: .offset(y: -yOffset))
        )
    }

    var body: some View {
        let actions = buildActions(for: email)
        EmailDetailView(
            email: email,
            accountID: accountID,
            mailStore: mailStore,
            actions: actions,
            attachmentIndexer: attachmentIndexer,
            allLabels: allLabels,
            fromAddress: resolvedFromAddress(for: email),
            mailDatabase: mailDatabase,
            contacts: contacts
        )
        .id(email.id)
        .transition(softDirectionalTransition(from: selectionDirection))
        .animation(reduceMotion ? nil : VikAnimation.contentSwitch, value: email.id)
        .navigationSplitViewColumnWidth(min: 500, ideal: 700)
    }

    /// Builds the actions struct for the given email. Separated from the view builder
    /// so SwiftUI can short-circuit the detail view via `.id(email.id)` without
    /// re-evaluating closures when only unrelated state changed.
    private func buildActions(for email: Email) -> EmailDetailActions {
        let selectNextFn = selectNext
        let msgID = email.gmailMessageID

        var actions = EmailDetailActions.contentActions(
            panelCoordinator: panelCoordinator,
            onUnsubscribe: { url, oneClick, msgID in
                await actionCoordinator.unsubscribe(url: url, oneClick: oneClick, messageID: msgID, accountID: accountID)
            },
            checkUnsubscribed: { msgID in
                actionCoordinator.isUnsubscribed(messageID: msgID, accountID: accountID)
            },
            extractBodyUnsubscribeURL: { html in
                actionCoordinator.extractBodyUnsubscribeURL(from: html)
            },
            onLoadDraft: { draftID, acctID in
                try await actionCoordinator.loadDraft(id: draftID, accountID: acctID, format: "full")
            }
        )

        // Email mutations
        actions.onArchive = selectedFolder == .archive ? nil : { Task { await actionCoordinator.archiveEmail(email, selectNext: selectNextFn) } }
        actions.onDelete = selectedFolder == .trash ? nil : { Task { await actionCoordinator.deleteEmail(email, selectNext: selectNextFn) } }
        actions.onMoveToInbox = selectedFolder == .archive || selectedFolder == .trash
            ? { Task { await actionCoordinator.moveToInboxEmail(email, selectedFolder: selectedFolder, selectNext: selectNextFn) } } : nil
        actions.onDeletePermanently = selectedFolder == .trash
            ? { Task { await actionCoordinator.deletePermanentlyEmail(email, selectNext: selectNextFn) } } : nil
        actions.onMarkNotSpam = selectedFolder == .spam
            ? { Task { await actionCoordinator.markNotSpamEmail(email, selectNext: selectNextFn) } } : nil
        actions.onToggleStar = { _ in
            Task { await actionCoordinator.toggleStarEmail(email) }
        }
        actions.onMarkUnread = { Task { await actionCoordinator.markUnreadEmail(email) } }
        actions.onSnooze = { date in Task { await actionCoordinator.snoozeEmail(email, until: date, selectNext: selectNextFn) } }

        // Labels
        actions.onAddLabel = { labelID in
            guard let msgID else { return }
            Task { await actionCoordinator.addLabelToEmail(labelID, to: msgID) }
        }
        actions.onRemoveLabel = { labelID in
            guard let msgID else { return }
            Task { await actionCoordinator.removeLabelFromEmail(labelID, from: msgID) }
        }
        actions.onCreateAndAddLabel = { name, completion in
            guard let msgID else { completion(nil); return }
            Task {
                let labelID = await actionCoordinator.createAndAddLabelToEmail(name: name, to: msgID)
                completion(labelID)
            }
        }

        // Compose
        actions.onReply = { mode in startCompose(mode) }
        actions.onReplyAll = { mode in startCompose(mode) }
        actions.onForward = { mode in startCompose(mode) }

        // Contact popover
        actions.onComposeTo = { email in startCompose(.newTo(to: email)) }
        actions.onSearchSender = { email in Task { await mailboxViewModel.search(query: "from:\(email)") } }

        // Email-specific content overrides
        actions.onMessagesRead = { messageIDs in Task { await mailboxViewModel.labelMutations.applyReadLocally(messageIDs) } }

        // Calendar context navigation
        actions.onNavigateToCalendar = { event in switchToCalendar?(event) }

        return actions
    }
}
