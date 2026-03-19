import SwiftUI

struct DetailPaneView: View {
    let selectedEmail: Email?
    let selectedEmailIDs: Set<String>
    let selectedFolder: Folder
    let displayedEmails: [Email]

    // MARK: - Extracted from AppCoordinator (H8)

    let actionCoordinator: EmailActionCoordinator
    let mailboxViewModel: MailboxViewModel
    let mailStore: MailStore
    let accountID: String
    let fromAddress: String
    let composeMode: ComposeMode
    let signatureForNew: String
    let signatureForReply: String
    let panelCoordinator: PanelCoordinator
    let attachmentIndexer: AttachmentIndexer?
    let contacts: [StoredContact]
    let mailDatabase: MailDatabase?
    let selectNext: (Email?) -> Void
    let clearSelection: () -> Void
    let deselectAll: () -> Void
    let startCompose: (ComposeMode) -> Void
    let discardDraft: (UUID) -> Void
    let selectionDirection: Edge
    let navigatePrevious: () -> Void
    let navigateNext: () -> Void
    var switchToCalendar: (() -> Void)?

    /// Resolves the best send-as alias for the given email, falling back to the primary account address.
    /// For outgoing folders (Sent), recipients are outbound contacts — no alias will match, so this
    /// safely falls back to the primary address.
    private func resolvedFromAddress(for email: Email) -> String {
        mailboxViewModel.sendAsAliases.bestAlias(
            toRecipients: email.recipients.map(\.email),
            ccRecipients: email.cc.map(\.email)
        ) ?? fromAddress
    }

    /// Resolves the from address for compose mode by looking up the original thread's email.
    /// Note: mailboxViewModel.emails contains thread representatives for the current folder only.
    /// If the original thread is not loaded (e.g., editing a draft from the Drafts folder),
    /// alias resolution falls back to the primary address.
    private func resolvedFromAddressForCompose() -> String {
        switch composeMode {
        case .reply(_, _, _, _, let threadID, _, _),
             .replyAll(_, _, _, _, _, let threadID, _, _):
            if let original = mailboxViewModel.emails.first(where: { $0.gmailThreadID == threadID }) {
                return resolvedFromAddress(for: original)
            }
            return fromAddress
        default:
            return fromAddress
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isMultiSelect: Bool { selectedEmailIDs.count > 1 }

    private func softDirectionalTransition(from edge: Edge) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let yOffset: CGFloat = edge == .bottom ? OffsetToken.small : -OffsetToken.small
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: yOffset)),
            removal: .opacity.combined(with: .offset(y: -yOffset))
        )
    }

    private var isEditingDraft: Bool {
        guard let email = selectedEmail else { return false }
        return email.isDraft
    }

    // MARK: - Derived Selection (M2)

    private var selectedEmails: [Email] {
        displayedEmails.filter { selectedEmailIDs.contains($0.id.uuidString) }
    }

    var body: some View {
        Group {
            if isMultiSelect {
                bulkActionView
                    .transition(.opacity.combined(with: .scale(scale: ScaleToken.enterFrom)))
            } else if isEditingDraft, let draftId = selectedEmail?.id {
                composeView(draftId: draftId)
            } else if let email = selectedEmail {
                emailDetailView(email: email)
                    .transition(softDirectionalTransition(from: selectionDirection))
            } else {
                emptyState
                    .transition(.opacity.combined(with: .scale(scale: ScaleToken.enterFrom)))
            }
        }
        .animation(reduceMotion ? nil : VikAnimation.contentSwitch, value: selectedEmail?.id)
        .animation(reduceMotion ? nil : VikAnimation.contentSwitch, value: isMultiSelect)
        .navigationSplitViewColumnWidth(min: 500, ideal: 700)
    }

    // MARK: - Bulk Actions

    private var bulkActionView: some View {
        BulkActionBarView(
            count: selectedEmailIDs.count,
            selectedFolder: selectedFolder,
            onArchive:     { Task { await actionCoordinator.bulkArchive(selectedEmails, onClear: clearSelection) } },
            onDelete:      { Task { await actionCoordinator.bulkDelete(selectedEmails, onClear: clearSelection) } },
            onMarkUnread:  { Task { await actionCoordinator.bulkMarkUnread(selectedEmails, onClear: deselectAll) } },
            onMarkRead:    { Task { await actionCoordinator.bulkMarkRead(selectedEmails, onClear: deselectAll) } },
            onToggleStar:  { Task { for e in selectedEmails { await actionCoordinator.toggleStarEmail(e) } } },
            onMoveToInbox: { Task { await actionCoordinator.bulkMoveToInbox(selectedEmails, selectedFolder: selectedFolder, onClear: clearSelection) } },
            onDeselectAll: deselectAll
        )
    }

    // MARK: - Compose

    private func composeView(draftId: UUID) -> some View {
        ComposeView(
            mailStore: mailStore,
            draftId: draftId,
            accountID: accountID,
            fromAddress: resolvedFromAddressForCompose(),
            mode: composeMode,
            sendAsAliases: mailboxViewModel.sendAsAliases,
            signatureForNew: signatureForNew,
            signatureForReply: signatureForReply,
            contacts: contacts,
            onDiscard: { discardDraft(draftId) },
            onOpenLink: { url in panelCoordinator.openInAppBrowser(url: url) }
        )
        .id(draftId)
    }

    // MARK: - Email Detail

    private func emailDetailView(email: Email) -> some View {
        let actions = buildActions(for: email)
        return EmailDetailView(
            email: email,
            accountID: accountID,
            mailStore: mailStore,
            actions: actions,
            attachmentIndexer: attachmentIndexer,
            allLabels: mailboxViewModel.labels,
            fromAddress: resolvedFromAddress(for: email),
            mailDatabase: mailDatabase,
            contacts: contacts
        )
        .id(email.id)
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
        actions.onToggleStar = { isCurrentlyStarred in
            guard let msgID else { return }
            Task { await mailboxViewModel.toggleStar(msgID, isStarred: isCurrentlyStarred) }
        }
        actions.onMarkUnread = { Task { await actionCoordinator.markUnreadEmail(email) } }
        actions.onSnooze = { date in Task { await actionCoordinator.snoozeEmail(email, until: date, selectNext: selectNextFn) } }

        // Labels
        actions.onAddLabel = { labelID in
            guard let msgID else { return }
            Task { await mailboxViewModel.addLabel(labelID, to: msgID) }
        }
        actions.onRemoveLabel = { labelID in
            guard let msgID else { return }
            Task { await mailboxViewModel.removeLabel(labelID, from: msgID) }
        }
        actions.onCreateAndAddLabel = { name, completion in
            guard let msgID else { completion(nil); return }
            Task {
                let labelID = await mailboxViewModel.createAndAddLabel(name: name, to: msgID)
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
        actions.onMessagesRead = { messageIDs in Task { await mailboxViewModel.applyReadLocally(messageIDs) } }

        // Calendar context navigation
        actions.onNavigateToCalendar = switchToCalendar

        return actions
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.xl) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tint.opacity(OpacityToken.disabled))
                .symbolEffect(.breathe.plain, isActive: true)

            VStack(spacing: Spacing.sm) {
                Text(emptyStateTitle)
                    .font(Typography.title)
                    .foregroundStyle(.secondary)

                Text(emptyStateDescription)
                    .font(Typography.subheadRegular)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var emptyStateIcon: String {
        switch selectedFolder {
        case .drafts:        "doc.text"
        case .sent:          "paperplane"
        case .trash:         "trash"
        case .spam:          "exclamationmark.shield"
        case .starred:       "star"
        case .archive:       "archivebox"
        case .attachments:   "paperclip"
        case .subscriptions: "newspaper"
        default:             "envelope.open"
        }
    }

    private var emptyStateTitle: String {
        switch selectedFolder {
        case .drafts:        "No Draft Selected"
        case .sent:          "No Email Selected"
        case .starred:       "No Email Selected"
        case .archive:       "No Email Selected"
        case .attachments:   "No Email Selected"
        case .subscriptions: "No Subscription Selected"
        default:             "No Email Selected"
        }
    }

    private var emptyStateDescription: String {
        switch selectedFolder {
        case .drafts:        "Pick a draft to continue writing"
        case .sent:          "Pick a sent email to view"
        case .starred:       "Pick a starred email to read"
        case .archive:       "Pick an archived email to read"
        case .attachments:   "Pick an email to view its attachments"
        case .subscriptions: "Pick a subscription to view"
        default:             "Pick an email from the left to start reading"
        }
    }
}
