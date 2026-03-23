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
    let selectedEmails: [Email]
    let clearSelection: () -> Void

    @State private var filterEmail: Email?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var navigationTitleText: String {
        if selectedFolder == .labels {
            return selectedLabel?.name ?? Folder.labels.rawValue
        }
        return selectedFolder.rawValue
    }

    /// Non-optional binding for CategoryTabBar, mapping nil to .all.
    private var categoryBinding: Binding<InboxCategory> {
        Binding(
            get: { selectedInboxCategory ?? .all },
            set: { selectedInboxCategory = $0 }
        )
    }

    var body: some View {
        @Bindable var vm = mailboxViewModel
        VStack(spacing: 0) {
            OfflineBannerView()
            CategoryTabBarSection(
                mailboxViewModel: mailboxViewModel,
                selectedFolder: selectedFolder,
                selectedCategory: categoryBinding
            )
            EmailListSection(
                emails: emails,
                isLoading: isLoading,
                selectedFolder: selectedFolder,
                searchResetTrigger: searchResetTrigger,
                mailboxViewModel: mailboxViewModel,
                actionCoordinator: actionCoordinator,
                selectNext: selectNext,
                startCompose: startCompose,
                emptyTrashRequested: emptyTrashRequested,
                emptySpamRequested: emptySpamRequested,
                loadCurrentFolder: loadCurrentFolder,
                selectedEmails: selectedEmails,
                clearSelection: clearSelection,
                filterEmail: $filterEmail,
                searchFocusTrigger: $searchFocusTrigger,
                selectedEmail: $selectedEmail,
                selectedEmailIDs: $selectedEmailIDs,
                priorityFilterOn: $vm.priorityFilterEnabled
            )
                .id("\(selectedFolder.rawValue)-\((selectedInboxCategory ?? .all).rawValue)")
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: OffsetToken.nudge)),
                    removal: .opacity.combined(with: .offset(y: -OffsetToken.nudge))
                ))
                .animation(reduceMotion ? nil : VikAnimation.contentSwitch, value: selectedInboxCategory)
                .animation(reduceMotion ? nil : VikAnimation.folderSwitch, value: selectedFolder)
        }
        .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 480)
        .navigationTitle(navigationTitleText)
        .toolbar(removing: .sidebarToggle)
        .safeAreaPadding(.leading, isSidebarCollapsed ? 8 : 0)
        .safeAreaPadding(.top, isSidebarCollapsed ? 6 : 0)
        .animation(reduceMotion ? nil : VikAnimation.springDefault, value: isSidebarCollapsed)
        .sheet(item: $filterEmail) { email in
            FilterEditorView(
                viewModel: FiltersViewModel(accountID: mailboxViewModel.accountID),
                onSave: { _ in },
                prefillFrom: email.sender.email
            )
        }
    }
}

// MARK: - Offline Banner (Issue 5)

private struct OfflineBannerView: View {
    @State private var network = NetworkMonitor.shared
    @State private var offlineQueue = OfflineActionQueue.shared

    var body: some View {
        if !network.isConnected {
            HStack {
                Image(systemName: "wifi.slash")
                Text("You're offline. Changes will sync when connected.")
                if offlineQueue.pendingCount > 0 {
                    Text("(\(offlineQueue.pendingCount) pending)")
                        .font(Typography.captionRegular)
                        .fontWeight(.medium)
                }
                Spacer()
            }
            .font(Typography.captionRegular)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(SemanticColor.warning.opacity(OpacityToken.highlight))
        }
    }
}

// MARK: - Category Tab Bar (Issue 6)

private struct CategoryTabBarSection: View {
    let mailboxViewModel: MailboxViewModel
    let selectedFolder: Folder
    @Binding var selectedCategory: InboxCategory

    var body: some View {
        if selectedFolder == .inbox {
            CategoryTabBar(
                selectedCategory: $selectedCategory,
                unreadCounts: mailboxViewModel.categoryUnreadCounts
            )
            Divider()
        }
    }
}

// MARK: - Email List (Issue 7)

private struct EmailListSection: View {
    let emails: [Email]
    let isLoading: Bool
    let selectedFolder: Folder
    let searchResetTrigger: Int
    let mailboxViewModel: MailboxViewModel
    let actionCoordinator: EmailActionCoordinator
    let selectNext: (Email?) -> Void
    let startCompose: (ComposeMode) -> Void
    let emptyTrashRequested: (Int) -> Void
    let emptySpamRequested: (Int) -> Void
    let loadCurrentFolder: () async -> Void
    let selectedEmails: [Email]
    let clearSelection: () -> Void
    @Binding var filterEmail: Email?
    @Binding var searchFocusTrigger: Bool
    @Binding var selectedEmail: Email?
    @Binding var selectedEmailIDs: Set<String>
    @Binding var priorityFilterOn: Bool

    var body: some View {
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
            selectedFolder: .constant(selectedFolder),
            priorityFilterOn: $priorityFilterOn,
            showPriorityFilter: selectedFolder == .inbox
        )
    }
}
