import SwiftUI

struct ListPaneView: View {
    let emails: [Email]
    let isLoading: Bool
    @Binding var selectedFolder: Folder
    let searchResetTrigger: Int
    @Binding var selectedEmail: Email?
    @Binding var selectedEmailIDs: Set<String>
    @Binding var searchFocusTrigger: Bool
    var selectedLabel: GmailLabel?

    // MARK: - Extracted from AppCoordinator (H8)

    let actionCoordinator: EmailActionCoordinator
    let mailboxViewModel: MailboxViewModel
    @Binding var selectedInboxCategory: InboxCategory?
    let selectNext: (Email?) -> Void
    let startCompose: (ComposeMode) -> Void
    let emptyTrashRequested: (Int) -> Void
    let emptySpamRequested: (Int) -> Void
    let loadCurrentFolder: () async -> Void

    @State private var selectedCategory: InboxCategory = .all

    private var navigationTitleText: String {
        if selectedFolder == .labels {
            return selectedLabel?.name ?? Folder.labels.rawValue
        }
        return selectedFolder.rawValue
    }

    // MARK: - Derived Selection (M2)

    private var selectedEmails: [Email] {
        emails.filter { selectedEmailIDs.contains($0.id.uuidString) }
    }

    private func clearSelection() {
        selectedEmail = nil
        selectedEmailIDs = []
    }

    var body: some View {
        VStack(spacing: 0) {
            if !actionCoordinator.isConnected {
                HStack {
                    Image(systemName: "wifi.slash")
                    Text("You're offline. Changes will sync when connected.")
                    if actionCoordinator.pendingOfflineActionCount > 0 {
                        Text("(\(actionCoordinator.pendingOfflineActionCount) pending)")
                            .fontWeight(.medium)
                    }
                    Spacer()
                }
                .font(Typography.captionRegular)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(SemanticColor.warning.opacity(0.08))
            }
            if selectedFolder == .inbox {
                @Bindable var vm = mailboxViewModel
                CategoryTabBar(
                    selectedCategory: $selectedCategory,
                    priorityFilterOn: $vm.priorityFilterEnabled,
                    unreadCounts: mailboxViewModel.categoryUnreadCounts
                )
                Divider()
            }
            emailList
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        .navigationTitle(navigationTitleText)
        .onChange(of: selectedCategory) { _, newCategory in
            selectedInboxCategory = newCategory
        }
        .onChange(of: selectedInboxCategory) { _, newValue in
            selectedCategory = newValue ?? .all
        }
    }

    private var emailList: some View {
        EmailListView(
            emails: emails,
            isLoading: isLoading,
            accountID: mailboxViewModel.accountID,
            actions: EmailListActions(
                onArchive:           { email in Task { await actionCoordinator.archiveEmail(email, selectNext: selectNext) } },
                onDelete:            { email in Task { await actionCoordinator.deleteEmail(email, selectNext: selectNext) } },
                onToggleStar:        { email in Task { await actionCoordinator.toggleStarEmail(email) } },
                onMarkUnread:        { email in Task { await actionCoordinator.markUnreadEmail(email) } },
                onMarkRead:          { email in Task { await actionCoordinator.markReadEmail(email) } },
                onMarkSpam:          { email in Task { await actionCoordinator.markSpamEmail(email, selectNext: selectNext) } },
                onUnsubscribe:       { actionCoordinator.unsubscribeEmail($0) },
                onMoveToInbox:       { email in Task { await actionCoordinator.moveToInboxEmail(email, selectedFolder: selectedFolder, selectNext: selectNext) } },
                onDeletePermanently: { email in Task { await actionCoordinator.deletePermanentlyEmail(email, selectNext: selectNext) } },
                onMarkNotSpam:       { email in Task { await actionCoordinator.markNotSpamEmail(email, selectNext: selectNext) } },
                onSnooze:            { email, date in Task { await actionCoordinator.snoozeEmail(email, until: date, selectNext: selectNext) } },
                onUnsnooze:          selectedFolder == .snoozed ? { email in actionCoordinator.unsnoozeEmail(messageId: email.gmailMessageID ?? "", accountID: mailboxViewModel.accountID) } : nil,
                onReply: { email in
                    startCompose(EmailDetailViewModel.replyMode(for: email))
                },
                onReplyAll: { email in
                    startCompose(EmailDetailViewModel.replyAllMode(for: email))
                },
                onForward: { email in
                    startCompose(EmailDetailViewModel.forwardMode(for: email))
                },
                onBulkArchive:    { Task { await actionCoordinator.bulkArchive(selectedEmails, onClear: clearSelection) } },
                onBulkDelete:     { Task { await actionCoordinator.bulkDelete(selectedEmails, onClear: clearSelection) } },
                onBulkMarkUnread: { Task { await actionCoordinator.bulkMarkUnread(selectedEmails) { selectedEmailIDs = [] } } },
                onBulkMarkRead:   { Task { await actionCoordinator.bulkMarkRead(selectedEmails) { selectedEmailIDs = [] } } },
                onBulkToggleStar: { Task { for e in selectedEmails { await actionCoordinator.toggleStarEmail(e) } } },
                onEmptyTrash: {
                    actionCoordinator.emptyTrash(accountID: mailboxViewModel.accountID) { count in
                        emptyTrashRequested(count)
                    }
                },
                onEmptySpam: {
                    actionCoordinator.emptySpam(accountID: mailboxViewModel.accountID) { count in
                        emptySpamRequested(count)
                    }
                },
                onSearch: { query in
                    if query.isEmpty {
                        Task { await loadCurrentFolder() }
                    } else {
                        Task { await mailboxViewModel.search(query: query) }
                    }
                },
                onRefresh: { await loadCurrentFolder() },
                onLoadMore: { mailboxViewModel.loadMore() }
            ),
            searchResetTrigger: searchResetTrigger,
            hasMoreEmails: mailboxViewModel.hasMoreEmails,
            isLoadingMore: mailboxViewModel.isLoadingMore,
            searchFocusTrigger: $searchFocusTrigger,
            selectedEmail: $selectedEmail,
            selectedEmailIDs: $selectedEmailIDs,
            selectedFolder: $selectedFolder
        )
    }
}
