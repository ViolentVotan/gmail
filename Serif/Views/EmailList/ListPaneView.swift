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

    let coordinator: AppCoordinator

    @State private var selectedCategory: InboxCategory = .all

    // MARK: - Convenience Accessors

    private var actionCoordinator: EmailActionCoordinator { coordinator.actionCoordinator }
    private var mailboxViewModel: MailboxViewModel { coordinator.mailboxViewModel }

    private var navigationTitleText: String {
        if selectedFolder == .labels {
            return selectedLabel?.name ?? Folder.labels.rawValue
        }
        return selectedFolder.rawValue
    }

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
                .background(.yellow.opacity(0.1))
            }
            if selectedFolder == .inbox {
                @Bindable var vm = coordinator.mailboxViewModel
                CategoryTabBar(
                    selectedCategory: $selectedCategory,
                    priorityFilterOn: $vm.priorityFilterEnabled,
                    unreadCounts: coordinator.mailboxViewModel.categoryUnreadCounts
                )
                Divider()
            }
            emailList
        }
        .navigationSplitViewColumnWidth(min: 500, ideal: 500, max: 500)
        .navigationTitle(navigationTitleText)
        .onChange(of: selectedCategory) { _, newCategory in
            coordinator.selectedInboxCategory = newCategory
        }
    }

    private var emailList: some View {
        EmailListView(
            emails: emails,
            isLoading: isLoading,
            accountID: mailboxViewModel.accountID,
            actions: EmailListActions(
                onArchive:           { actionCoordinator.archiveEmail($0, selectNext: { coordinator.selectNext($0) }) },
                onDelete:            { actionCoordinator.deleteEmail($0, selectNext: { coordinator.selectNext($0) }) },
                onToggleStar:        { actionCoordinator.toggleStarEmail($0) },
                onMarkUnread:        { actionCoordinator.markUnreadEmail($0) },
                onMarkSpam:          { actionCoordinator.markSpamEmail($0, selectNext: { coordinator.selectNext($0) }) },
                onUnsubscribe:       { actionCoordinator.unsubscribeEmail($0) },
                onMoveToInbox:       { actionCoordinator.moveToInboxEmail($0, selectedFolder: selectedFolder, selectNext: { coordinator.selectNext($0) }) },
                onDeletePermanently: { actionCoordinator.deletePermanentlyEmail($0, selectNext: { coordinator.selectNext($0) }) },
                onMarkNotSpam:       { actionCoordinator.markNotSpamEmail($0, selectNext: { coordinator.selectNext($0) }) },
                onSnooze:            { actionCoordinator.snoozeEmail($0, until: $1, selectNext: { coordinator.selectNext($0) }) },
                onReply: { email in
                    coordinator.startCompose(mode: EmailDetailViewModel.replyMode(for: email))
                },
                onReplyAll: { email in
                    coordinator.startCompose(mode: EmailDetailViewModel.replyAllMode(for: email))
                },
                onForward: { email in
                    coordinator.startCompose(mode: EmailDetailViewModel.forwardMode(for: email))
                },
                onBulkArchive:    { actionCoordinator.bulkArchive(selectedEmails, onClear: clearSelection) },
                onBulkDelete:     { actionCoordinator.bulkDelete(selectedEmails, onClear: clearSelection) },
                onBulkMarkUnread: { actionCoordinator.bulkMarkUnread(selectedEmails) { selectedEmailIDs = [] } },
                onBulkMarkRead:   { actionCoordinator.bulkMarkRead(selectedEmails) { selectedEmailIDs = [] } },
                onBulkToggleStar: { for e in selectedEmails { actionCoordinator.toggleStarEmail(e) } },
                onEmptyTrash: {
                    actionCoordinator.emptyTrash(accountID: mailboxViewModel.accountID) { count in
                        coordinator.emptyTrashRequested(count: count)
                    }
                },
                onEmptySpam: {
                    actionCoordinator.emptySpam(accountID: mailboxViewModel.accountID) { count in
                        coordinator.emptySpamRequested(count: count)
                    }
                },
                onSearch: { query in
                    if query.isEmpty {
                        Task { await coordinator.loadCurrentFolder() }
                    } else {
                        Task { await mailboxViewModel.search(query: query) }
                    }
                },
                onRefresh: { await coordinator.loadCurrentFolder() }
            ),
            searchResetTrigger: searchResetTrigger,
            searchFocusTrigger: $searchFocusTrigger,
            selectedEmail: $selectedEmail,
            selectedEmailIDs: $selectedEmailIDs,
            selectedFolder: $selectedFolder
        )
    }
}
