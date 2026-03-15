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
        .onChange(of: coordinator.selectedInboxCategory) { _, newValue in
            selectedCategory = newValue ?? .all
        }
    }

    private var emailList: some View {
        EmailListView(
            emails: emails,
            isLoading: isLoading,
            accountID: mailboxViewModel.accountID,
            actions: EmailListActions(
                onArchive:           { email in Task { await actionCoordinator.archiveEmail(email, selectNext: { coordinator.selectNext($0) }) } },
                onDelete:            { email in Task { await actionCoordinator.deleteEmail(email, selectNext: { coordinator.selectNext($0) }) } },
                onToggleStar:        { email in Task { await actionCoordinator.toggleStarEmail(email) } },
                onMarkUnread:        { email in Task { await actionCoordinator.markUnreadEmail(email) } },
                onMarkSpam:          { email in Task { await actionCoordinator.markSpamEmail(email, selectNext: { coordinator.selectNext($0) }) } },
                onUnsubscribe:       { actionCoordinator.unsubscribeEmail($0) },
                onMoveToInbox:       { email in Task { await actionCoordinator.moveToInboxEmail(email, selectedFolder: selectedFolder, selectNext: { coordinator.selectNext($0) }) } },
                onDeletePermanently: { email in Task { await actionCoordinator.deletePermanentlyEmail(email, selectNext: { coordinator.selectNext($0) }) } },
                onMarkNotSpam:       { email in Task { await actionCoordinator.markNotSpamEmail(email, selectNext: { coordinator.selectNext($0) }) } },
                onSnooze:            { email, date in Task { await actionCoordinator.snoozeEmail(email, until: date, selectNext: { coordinator.selectNext($0) }) } },
                onUnsnooze:          selectedFolder == .snoozed ? { email in actionCoordinator.unsnoozeEmail(messageId: email.gmailMessageID ?? "", accountID: mailboxViewModel.accountID) } : nil,
                onReply: { email in
                    coordinator.startCompose(mode: EmailDetailViewModel.replyMode(for: email))
                },
                onReplyAll: { email in
                    coordinator.startCompose(mode: EmailDetailViewModel.replyAllMode(for: email))
                },
                onForward: { email in
                    coordinator.startCompose(mode: EmailDetailViewModel.forwardMode(for: email))
                },
                onBulkArchive:    { Task { await actionCoordinator.bulkArchive(selectedEmails, onClear: clearSelection) } },
                onBulkDelete:     { Task { await actionCoordinator.bulkDelete(selectedEmails, onClear: clearSelection) } },
                onBulkMarkUnread: { Task { await actionCoordinator.bulkMarkUnread(selectedEmails) { selectedEmailIDs = [] } } },
                onBulkMarkRead:   { Task { await actionCoordinator.bulkMarkRead(selectedEmails) { selectedEmailIDs = [] } } },
                onBulkToggleStar: { Task { for e in selectedEmails { await actionCoordinator.toggleStarEmail(e) } } },
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
