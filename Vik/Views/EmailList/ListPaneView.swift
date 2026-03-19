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
    var isSidebarCollapsed: Bool = false

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
    @State private var filterEmail: Email?

    private var navigationTitleText: String {
        if selectedFolder == .labels {
            return selectedLabel?.name ?? Folder.labels.rawValue
        }
        return selectedFolder.rawValue
    }

    // MARK: - Derived Selection (M2)

    @State private var selectedEmails: [Email] = []

    private func recomputeSelectedEmails() {
        selectedEmails = emails.filter { selectedEmailIDs.contains($0.id.uuidString) }
    }

    private func clearSelection() {
        selectedEmail = nil
        selectedEmailIDs = []
    }

    var body: some View {
        @Bindable var vm = mailboxViewModel
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
                .background(SemanticColor.warning.opacity(OpacityToken.highlight))
            }
            if selectedFolder == .inbox {
                CategoryTabBar(
                    selectedCategory: $selectedCategory,
                    unreadCounts: mailboxViewModel.categoryUnreadCounts
                )
                Divider()
            }
            emailList(priorityFilterOn: $vm.priorityFilterEnabled)
                .id("\(selectedFolder.rawValue)-\(selectedCategory.rawValue)")
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .opacity.combined(with: .offset(y: -OffsetToken.nudge))
                ))
                .animation(VikAnimation.contentSwitch, value: selectedCategory)
                .animation(VikAnimation.folderSwitch, value: selectedFolder)
        }
        .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 480)
        .navigationTitle(navigationTitleText)
        .toolbar(removing: .sidebarToggle)
        .safeAreaPadding(.leading, isSidebarCollapsed ? 8 : 0)
        .safeAreaPadding(.top, isSidebarCollapsed ? 6 : 0)
        .animation(VikAnimation.springDefault, value: isSidebarCollapsed)
        .sheet(item: $filterEmail) { email in
            FilterEditorView(
                viewModel: FiltersViewModel(accountID: mailboxViewModel.accountID),
                onSave: { _ in },
                prefillFrom: email.sender.email
            )
        }
        .onChange(of: selectedCategory) { _, newCategory in
            selectedInboxCategory = newCategory
        }
        .onChange(of: selectedInboxCategory) { _, newValue in
            selectedCategory = newValue ?? .all
        }
        .onChange(of: selectedEmailIDs) { _, _ in recomputeSelectedEmails() }
        .onChange(of: emails) { _, _ in recomputeSelectedEmails() }
    }

    private func emailList(priorityFilterOn: Binding<Bool>) -> some View {
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
                onCreateFilter: { email in filterEmail = email },
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
                onCompose: { startCompose(.new) },
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
            selectedFolder: $selectedFolder,
            priorityFilterOn: priorityFilterOn,
            showPriorityFilter: selectedFolder == .inbox
        )
    }
}
