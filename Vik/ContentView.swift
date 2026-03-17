import SwiftUI

struct ContentView: View {
    var appearanceManager: AppearanceManager
    @State private var coordinator = AppCoordinator()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var commandPalette = CommandPaletteViewModel()
    @State private var showSnoozePicker = false

    enum AppFocus: Hashable {
        case sidebar
        case list
        case detail
    }

    @FocusState private var appFocus: AppFocus?
    @Namespace private var commandPaletteNamespace

    // MARK: - Body

    var body: some View {
        withLifecycle(
            mainLayout
                .preferredColorScheme(appearanceManager.colorScheme)
                .frame(minWidth: 960, minHeight: 600)
                .focusedSceneValue(\.appCoordinator, coordinator)
                .focusedSceneValue(\.commandPalette, commandPalette)
                .toolbar { toolbarContent }
                .alert("Empty Trash", isPresented: $coordinator.showEmptyTrashConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete All", role: .destructive) {
                        coordinator.selectedEmail = nil
                        Task { await coordinator.mailboxViewModel.emptyTrash() }
                    }
                } message: {
                    Text("This will permanently delete \(coordinator.trashTotalCount) message\(coordinator.trashTotalCount == 1 ? "" : "s"). This action cannot be undone.")
                }
                .alert("Empty Spam", isPresented: $coordinator.showEmptySpamConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete All", role: .destructive) {
                        coordinator.selectedEmail = nil
                        Task { await coordinator.mailboxViewModel.emptySpam() }
                    }
                } message: {
                    Text("This will permanently delete \(coordinator.spamTotalCount) spam message\(coordinator.spamTotalCount == 1 ? "" : "s"). This action cannot be undone.")
                }
        )
    }

    // MARK: - Main Layout

    private var mainLayout: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(
                    selectedFolder: $coordinator.selectedFolder,
                    selectedInboxCategory: $coordinator.selectedInboxCategory,
                    selectedLabel: $coordinator.selectedLabel,
                    selectedAccountID: $coordinator.selectedAccountID,
                    authViewModel: coordinator.authViewModel,
                    categoryUnreadCounts: coordinator.mailboxViewModel.categoryUnreadCounts,
                    userLabels: coordinator.mailboxViewModel.userLabels,
                    onRenameLabel: { label, newName in Task { await coordinator.renameLabel(label, to: newName) } },
                    onDeleteLabel: { label in Task { await coordinator.deleteLabel(label) } },
                    onDropToTrash: { msgId, accountID in
                        guard let email = coordinator.mailboxViewModel.emails.first(where: { $0.gmailMessageID == msgId }) else { return }
                        Task { await coordinator.actionCoordinator.deleteEmail(email, selectNext: { _ in }) }
                    },
                    onDropToArchive: { msgId, accountID in
                        guard let email = coordinator.mailboxViewModel.emails.first(where: { $0.gmailMessageID == msgId }) else { return }
                        Task { await coordinator.actionCoordinator.archiveEmail(email, selectNext: { _ in }) }
                    },
                    onDropToSpam: { msgId, accountID in
                        guard let email = coordinator.mailboxViewModel.emails.first(where: { $0.gmailMessageID == msgId }) else { return }
                        Task { await coordinator.actionCoordinator.markSpamEmail(email, selectNext: { _ in }) }
                    },
                    onDropToLabel: { msgId, labelId, accountID in
                        Task { await coordinator.mailboxViewModel.addLabel(labelId, to: msgId) }
                    },
                    onSignOut: { account in
                        coordinator.authViewModel.signOut(account)
                    },
                    onSetAsDefault: { id in AccountStore.shared.setAsDefault(id: id) },
                    onSetAccentColor: { id, hex in AccountStore.shared.setAccentColor(id: id, hex: hex) },
                    onShowDebug: {
                        coordinator.panelCoordinator.showDebug = true
                    },
                    onRefresh: {
                        Task { await coordinator.syncEngine?.triggerIncrementalSync() }
                    }
                )
                .focused($appFocus, equals: .sidebar)
            } content: {
                if coordinator.selectedFolder == .attachments {
                    AttachmentExplorerView(
                        store: coordinator.attachmentStore,
                        panelCoordinator: coordinator.panelCoordinator,
                        accountID: coordinator.accountID,
                        onViewMessage: { messageId in
                            coordinator.navigateToMessage(gmailMessageID: messageId)
                        },
                        onDownloadAttachment: coordinator.downloadAttachment
                    )
                    .navigationTitle("Attachments")
                } else {
                    ListPaneView(
                        emails: coordinator.displayedEmails,
                        isLoading: coordinator.listIsLoading,
                        selectedFolder: $coordinator.selectedFolder,
                        searchResetTrigger: coordinator.searchResetTrigger,
                        selectedEmail: $coordinator.selectedEmail,
                        selectedEmailIDs: $coordinator.selectedEmailIDs,
                        searchFocusTrigger: $coordinator.searchFocusTrigger,
                        selectedLabel: coordinator.selectedLabel,
                        actionCoordinator: coordinator.actionCoordinator,
                        mailboxViewModel: coordinator.mailboxViewModel,
                        selectedInboxCategory: $coordinator.selectedInboxCategory,
                        selectNext: { coordinator.selectNext($0) },
                        startCompose: { coordinator.startCompose(mode: $0) },
                        emptyTrashRequested: { coordinator.emptyTrashRequested(count: $0) },
                        emptySpamRequested: { coordinator.emptySpamRequested(count: $0) },
                        loadCurrentFolder: { await coordinator.loadCurrentFolder() }
                    )
                    .focused($appFocus, equals: .list)
                }
            } detail: {
                if coordinator.selectedFolder != .attachments {
                    DetailPaneView(
                        selectedEmail: coordinator.selectedEmail,
                        selectedEmailIDs: coordinator.selectedEmailIDs,
                        selectedFolder: coordinator.selectedFolder,
                        displayedEmails: coordinator.displayedEmails,
                        actionCoordinator: coordinator.actionCoordinator,
                        mailboxViewModel: coordinator.mailboxViewModel,
                        mailStore: coordinator.mailStore,
                        accountID: coordinator.accountID,
                        fromAddress: coordinator.fromAddress,
                        composeMode: coordinator.composeMode,
                        signatureForNew: coordinator.signatureForNew,
                        signatureForReply: coordinator.signatureForReply,
                        panelCoordinator: coordinator.panelCoordinator,
                        attachmentIndexer: coordinator.attachmentIndexer,
                        contacts: coordinator.contacts,
                        mailDatabase: coordinator.mailDatabase,
                        selectNext: { coordinator.selectNext($0) },
                        clearSelection: { coordinator.clearSelection() },
                        deselectAll: { coordinator.deselectAll() },
                        startCompose: { coordinator.startCompose(mode: $0) },
                        discardDraft: { coordinator.discardDraft(id: $0) }
                    )
                    .focused($appFocus, equals: .detail)
                }
            }
            .environment(coordinator.syncProgressManager)
            .navigationSplitViewStyle(.balanced)
            .windowResizeAnchor(.top)
            .onKeyPress(.tab, phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.option) else { return .ignored }
                if keyPress.modifiers.contains(.shift) {
                    switch appFocus {
                    case .sidebar: appFocus = .detail
                    case .list:    appFocus = .sidebar
                    case .detail:  appFocus = .list
                    case nil:      appFocus = .list
                    }
                } else {
                    switch appFocus {
                    case .sidebar: appFocus = .list
                    case .list:    appFocus = .detail
                    case .detail:  appFocus = .sidebar
                    case nil:      appFocus = .list
                    }
                }
                return .handled
            }
            .userActivity(UserActivityManager.viewEmailActivityType, isActive: coordinator.selectedEmail != nil) { activity in
                guard let email = coordinator.selectedEmail else { return }
                let source = UserActivityManager.activity(for: email, accountID: coordinator.accountID)
                activity.title = source.title
                activity.isEligibleForSearch = true
                activity.isEligibleForHandoff = false
                activity.targetContentIdentifier = source.targetContentIdentifier
                activity.contentAttributeSet = source.contentAttributeSet
                activity.userInfo = source.userInfo
            }
            .onContinueUserActivity("com.vikingz.vik.viewEmail") { activity in
                if let accountID = activity.userInfo?["accountID"] as? String,
                   !accountID.isEmpty,
                   coordinator.selectedAccountID != accountID {
                    coordinator.selectedAccountID = accountID
                }
                guard let messageId = activity.userInfo?["messageId"] as? String,
                      !messageId.isEmpty,
                      let email = coordinator.mailboxViewModel.emails.first(where: { $0.gmailMessageID == messageId })
                else { return }
                coordinator.selectedEmail = email
                coordinator.selectedEmailIDs = [messageId]
            }
            .userActivity("com.vikingz.vik.composeEmail", isActive: coordinator.isComposeActive) { activity in
                activity.title = "Composing email"
                activity.isEligibleForHandoff = true
            }

            KeyboardShortcutsView(coordinator: coordinator)

            UnifiedToastLayer()
                .zIndex(5)

            SlidePanelsOverlay(
                panels: coordinator.panelCoordinator,
                authViewModel: coordinator.authViewModel,
                selectedAccountID: $coordinator.selectedAccountID,
                attachmentStore: coordinator.attachmentStore,
                mailStore: coordinator.mailStore,
                mailDatabase: coordinator.mailDatabase,
                attachmentIndexer: coordinator.attachmentIndexer,
                onToggleStar: { [coordinator] msgID, isCurrentlyStarred, accountID in
                    coordinator.previewToggleStar(messageID: msgID, isCurrentlyStarred: isCurrentlyStarred, accountID: accountID)
                },
                onMarkUnread: { [coordinator] msgID, accountID in
                    coordinator.previewMarkUnread(messageID: msgID, accountID: accountID)
                },
                onMessagesRead: { [coordinator] messageIDs in
                    Task { await coordinator.mailboxViewModel.applyReadLocally(messageIDs) }
                }
            )

            if commandPalette.isVisible {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { commandPalette.dismiss() }
                    .zIndex(10)

                CommandPaletteView(viewModel: commandPalette)
                    .matchedGeometryEffect(id: "commandPalette", in: commandPaletteNamespace)
                    .zIndex(11)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !coordinator.panelCoordinator.isAnyOpen {
            ToolbarItem(placement: .primaryAction) {
                Button { coordinator.composeNewEmail() } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                }
                .help("Compose (\u{2318}N)")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            if let email = coordinator.selectedEmail {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        coordinator.startCompose(mode: EmailDetailViewModel.replyMode(for: email))
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .help("Reply")

                    if coordinator.selectedFolder != .archive {
                        Button {
                            Task { await coordinator.actionCoordinator.archiveEmail(email, selectNext: { coordinator.selectNext($0) }) }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .help("Archive (\u{2318}E)")
                    }

                    if coordinator.selectedFolder != .trash {
                        Button {
                            Task { await coordinator.actionCoordinator.deleteEmail(email, selectNext: { coordinator.selectNext($0) }) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .help("Delete (\u{2318}\u{232B})")
                    }

                    Button {
                        showSnoozePicker = true
                    } label: {
                        Label("Snooze", systemImage: "clock")
                    }
                    .help("Snooze")
                    .popover(isPresented: $showSnoozePicker) {
                        SnoozePickerView { date in
                            showSnoozePicker = false
                            Task { await coordinator.actionCoordinator.snoozeEmail(email, until: date, selectNext: { coordinator.selectNext($0) }) }
                        }
                    }
                }
            }

            if let email = coordinator.selectedEmail {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button {
                            coordinator.startCompose(mode: EmailDetailViewModel.replyAllMode(for: email))
                        } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }

                        Button {
                            coordinator.startCompose(mode: EmailDetailViewModel.forwardMode(for: email))
                        } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }

                        Divider()

                        Button {
                            guard let msgID = email.gmailMessageID else { return }
                            Task { await coordinator.mailboxViewModel.toggleStar(msgID, isStarred: email.isStarred) }
                        } label: {
                            Label(email.isStarred ? "Remove from Favorites" : "Add to Favorites", systemImage: email.isStarred ? "star.slash" : "star")
                        }

                        Button {
                            Task { await coordinator.actionCoordinator.markUnreadEmail(email) }
                        } label: { Label("Mark as Unread", systemImage: "envelope.badge") }

                        if coordinator.selectedFolder == .archive || coordinator.selectedFolder == .trash {
                            Button {
                                Task { await coordinator.actionCoordinator.moveToInboxEmail(email, selectedFolder: coordinator.selectedFolder, selectNext: { coordinator.selectNext($0) }) }
                            } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
                        }

                        Divider()

                        Button {
                            Task { await coordinator.actionCoordinator.printEmail(email) }
                        } label: {
                            Label("Print", systemImage: "printer")
                        }
                        .disabled(email.gmailMessageID == nil)

                        Divider()

                        if coordinator.selectedFolder == .spam {
                            Button {
                                Task { await coordinator.actionCoordinator.markNotSpamEmail(email, selectNext: { coordinator.selectNext($0) }) }
                            } label: { Label("Not Spam", systemImage: "tray.and.arrow.down") }
                        } else {
                            Button(role: .destructive) {
                                Task { await coordinator.actionCoordinator.markSpamEmail(email, selectNext: { coordinator.selectNext($0) }) }
                            } label: { Label("Report as Spam", systemImage: "exclamationmark.shield") }
                        }

                        if coordinator.selectedFolder == .trash {
                            Button(role: .destructive) {
                                Task { await coordinator.actionCoordinator.deletePermanentlyEmail(email, selectNext: { coordinator.selectNext($0) }) }
                            } label: { Label("Delete Permanently", systemImage: "trash.slash") }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .help("More actions")
                }
            }
        }
    }

    // MARK: - Lifecycle

    private func withLifecycle<V: View>(_ view: V) -> some View {
        view
            .modifier(LifecycleStateModifier(
                coordinator: coordinator,
                commandPalette: commandPalette,
                showSnoozePicker: $showSnoozePicker,
                snoozeCount: SnoozeStore.shared.items.count,
                scheduledCount: ScheduledSendStore.shared.items.count
            ))
            .modifier(LifecycleNotificationModifier(coordinator: coordinator))
    }

    /// State-change observers split out to help the type-checker.
    private struct LifecycleStateModifier: ViewModifier {
        let coordinator: AppCoordinator
        let commandPalette: CommandPaletteViewModel
        @Binding var showSnoozePicker: Bool
        let snoozeCount: Int
        let scheduledCount: Int

        func body(content: Content) -> some View {
            content
                .task {
                    commandPalette.buildCommands(coordinator: coordinator)
                    await coordinator.handleAppear()
                }
                .onChange(of: coordinator.selectedFolder) { _, newValue in coordinator.handleFolderChange(newValue) }
                .onChange(of: coordinator.selectedInboxCategory) { _, newValue in coordinator.handleCategoryChange(newValue) }
                .onChange(of: coordinator.selectedLabel?.id) { _, _ in coordinator.handleLabelChange() }
                .onChange(of: coordinator.selectedAccountID) { _, newValue in coordinator.handleAccountChange(newValue) }
                .onChange(of: coordinator.authViewModel.accounts) { oldValue, newValue in coordinator.handleAccountsChange(old: oldValue, new: newValue) }
                .onChange(of: NetworkMonitor.shared.isConnected) { _, connected in
                    if connected {
                        OfflineActionQueue.shared.startDraining()
                        Task { await coordinator.syncEngine?.triggerIncrementalSync() }
                    }
                }
                .onChange(of: coordinator.selectedEmail) { _, newValue in
                    showSnoozePicker = false
                    coordinator.handleSelectedEmailChange(newValue)
                }
                .onChange(of: coordinator.signatureForNew) { _, _ in if !coordinator.accountID.isEmpty { coordinator.saveSignatures(for: coordinator.accountID) } }
                .onChange(of: coordinator.signatureForReply) { _, _ in if !coordinator.accountID.isEmpty { coordinator.saveSignatures(for: coordinator.accountID) } }
                .onChange(of: snoozeCount) { _, _ in
                    coordinator.refreshSnoozedCacheIfNeeded()
                }
                .onChange(of: scheduledCount) { _, _ in
                    coordinator.refreshScheduledCacheIfNeeded()
                }
                .onChange(of: coordinator.mailboxViewModel.lastRestoredMessageID) { _, msgID in
                    guard let msgID else { return }
                    coordinator.mailboxViewModel.lastRestoredMessageID = nil
                    if let restoredEmail = coordinator.mailboxViewModel.emails.first(where: { $0.gmailMessageID == msgID }) {
                        coordinator.selectedEmail = restoredEmail
                        coordinator.selectedEmailIDs = [restoredEmail.id.uuidString]
                    }
                }
        }
    }

    /// Notification listeners split out to help the type-checker.
    private struct LifecycleNotificationModifier: ViewModifier {
        let coordinator: AppCoordinator

        func body(content: Content) -> some View {
            content
                .task {
                    await withDiscardingTaskGroup { group in
                        group.addTask {
                            for await notification in NotificationCenter.default.notifications(named: .composeEmailFromIntent) {
                                let recipient = notification.userInfo?["recipient"] as? String
                                await coordinator.composeNewEmail(recipient: recipient)
                            }
                        }
                        group.addTask {
                            for await notification in NotificationCenter.default.notifications(named: .searchEmailFromIntent) {
                                await MainActor.run {
                                    coordinator.selectedFolder = .inbox
                                    coordinator.searchFocusTrigger = true
                                }
                                if let query = notification.userInfo?["query"] as? String, !query.isEmpty {
                                    await coordinator.mailboxViewModel.search(query: query)
                                }
                            }
                        }
                        group.addTask {
                            for await notification in NotificationCenter.default.notifications(named: .quickReplyFromNotification) {
                                guard let messageId = notification.userInfo?["messageId"] as? String,
                                      let text = notification.userInfo?["text"] as? String,
                                      let accountID = notification.userInfo?["accountID"] as? String,
                                      !text.isEmpty
                                else { continue }
                                await coordinator.handleQuickReply(messageId: messageId, text: text, accountID: accountID)
                            }
                        }
                        group.addTask {
                            for await notification in NotificationCenter.default.notifications(named: .openEmailFromIntent) {
                                guard let messageId = notification.userInfo?["messageId"] as? String else { continue }
                                let accountID = notification.userInfo?["accountID"] as? String
                                await MainActor.run {
                                    if let accountID, !accountID.isEmpty,
                                       coordinator.selectedAccountID != accountID {
                                        coordinator.selectedAccountID = accountID
                                    }
                                    coordinator.navigateToMessage(gmailMessageID: messageId)
                                }
                            }
                        }
                        group.addTask {
                            for await notification in NotificationCenter.default.notifications(named: .replyEmailFromIntent) {
                                guard let messageId = notification.userInfo?["messageId"] as? String else { continue }
                                let accountID = notification.userInfo?["accountID"] as? String
                                let replyAll = notification.userInfo?["replyAll"] as? Bool ?? false
                                await MainActor.run {
                                    if let accountID, !accountID.isEmpty,
                                       coordinator.selectedAccountID != accountID {
                                        coordinator.selectedAccountID = accountID
                                    }
                                    coordinator.navigateAndReply(gmailMessageID: messageId, replyAll: replyAll)
                                }
                            }
                        }
                        group.addTask {
                            for await notification in NotificationCenter.default.notifications(named: .forwardEmailFromIntent) {
                                guard let messageId = notification.userInfo?["messageId"] as? String else { continue }
                                let accountID = notification.userInfo?["accountID"] as? String
                                let recipient = notification.userInfo?["to"] as? String
                                await MainActor.run {
                                    if let accountID, !accountID.isEmpty,
                                       coordinator.selectedAccountID != accountID {
                                        coordinator.selectedAccountID = accountID
                                    }
                                    coordinator.navigateAndForward(gmailMessageID: messageId, recipient: recipient)
                                }
                            }
                        }
                        group.addTask {
                            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                                await coordinator.syncEngine?.updatePollingInterval(appIsActive: true, windowIsKey: true)
                            }
                        }
                        group.addTask {
                            for await _ in NotificationCenter.default.notifications(named: NSApplication.didResignActiveNotification) {
                                await coordinator.syncEngine?.updatePollingInterval(appIsActive: false, windowIsKey: false)
                            }
                        }
                    }
                }
        }
    }

}
