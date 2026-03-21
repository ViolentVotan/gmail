import CoreSpotlight
import SwiftUI

struct ContentView: View {
    var appearanceManager: AppearanceManager
    @State private var coordinator = AppCoordinator()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isSidebarCollapsed = false
    @State private var commandPalette = CommandPaletteViewModel()
    @State private var showSnoozePicker = false
    @State private var showNewCalendarEvent = false
    @State private var newCalendarEventDraft: EventEditDraft? = nil
    @State private var newEventStartTime: Date? = nil
    @State private var showCalendarScopesAlert = false
    @State private var calendarScopesAccountID: String?
    @State private var showGmailScopesAlert = false
    @State private var gmailScopesAccountID: String?

    enum AppFocus: Hashable {
        case sidebar
        case list
        case detail
    }

    @FocusState private var appFocus: AppFocus?
    @Namespace private var commandPaletteNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sidebarWidth: CGFloat { isSidebarCollapsed ? 64 : 240 }

    // MARK: - Body

    var body: some View {
        @Bindable var dialogs = coordinator.dialogs
        return withLifecycle(
            mainLayout
                .preferredColorScheme(appearanceManager.colorScheme)
                .frame(minWidth: 1100, minHeight: 600)
                .focusedSceneValue(\.appCoordinator, coordinator)
                .focusedSceneValue(\.commandPalette, commandPalette)
                .toolbar { toolbarContent }
                .alert("Empty Trash", isPresented: $dialogs.showEmptyTrashConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete All", role: .destructive) {
                        coordinator.selection.selectedEmail = nil
                        Task { await coordinator.mailboxViewModel.emptyTrash() }
                    }
                } message: {
                    Text("This will permanently delete \(coordinator.dialogs.trashTotalCount) message\(coordinator.dialogs.trashTotalCount == 1 ? "" : "s"). This action cannot be undone.")
                }
                .alert("Empty Spam", isPresented: $dialogs.showEmptySpamConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete All", role: .destructive) {
                        coordinator.selection.selectedEmail = nil
                        Task { await coordinator.mailboxViewModel.emptySpam() }
                    }
                } message: {
                    Text("This will permanently delete \(coordinator.dialogs.spamTotalCount) spam message\(coordinator.dialogs.spamTotalCount == 1 ? "" : "s"). This action cannot be undone.")
                }
                .alert("Calendar Access Required", isPresented: $showCalendarScopesAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Re-authorize") {
                        guard let accountID = calendarScopesAccountID else { return }
                        Task {
                            try? await OAuthService.shared.reauthorize(
                                accountID: accountID,
                                presentingWindow: NSApp.keyWindow
                            )
                        }
                    }
                } message: {
                    Text("Calendar features require additional permissions. Please re-authorize to grant calendar access.")
                }
                .alert("Gmail Access Required", isPresented: $showGmailScopesAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Re-authorize") {
                        guard let accountID = gmailScopesAccountID else { return }
                        Task {
                            try? await OAuthService.shared.reauthorize(
                                accountID: accountID,
                                presentingWindow: NSApp.keyWindow
                            )
                        }
                    }
                } message: {
                    Text("Gmail features require additional permissions. Please re-authorize to grant access.")
                }
        )
    }

    // MARK: - Main Layout

    private var mainLayout: some View {
        @Bindable var navigation = coordinator.navigation
        return ZStack {
            HStack(spacing: 0) {
                SidebarContainer(
                    coordinator: coordinator,
                    isSidebarCollapsed: $isSidebarCollapsed,
                    appFocus: $appFocus,
                    sidebarWidth: sidebarWidth
                )

                ModeContentView(
                    coordinator: coordinator,
                    columnVisibility: $columnVisibility,
                    appFocus: $appFocus,
                    isSidebarCollapsed: isSidebarCollapsed,
                    showNewCalendarEvent: $showNewCalendarEvent,
                    newCalendarEventDraft: $newCalendarEventDraft,
                    newEventStartTime: $newEventStartTime,
                    reduceMotion: reduceMotion
                )
            }
            .environment(coordinator.syncProgressManager)
            .windowResizeAnchor(.top)
            .onChange(of: columnVisibility) { _, newValue in
                // Prevent the system from hiding the list column
                if newValue != .all { columnVisibility = .all }
            }
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
            .userActivity(UserActivityManager.viewEmailActivityType, isActive: coordinator.selection.selectedEmail != nil) { activity in
                guard let email = coordinator.selection.selectedEmail else { return }
                activity.title = email.subject
                activity.isEligibleForSearch = true
                activity.isEligibleForHandoff = false
                activity.targetContentIdentifier = email.gmailMessageID
                let attributes = CSSearchableItemAttributeSet(contentType: .emailMessage)
                attributes.subject = email.subject
                attributes.authorNames = [email.sender.name]
                attributes.authorEmailAddresses = [email.sender.email]
                attributes.contentDescription = String(email.preview.prefix(300))
                attributes.contentCreationDate = email.date
                if !email.recipients.isEmpty {
                    attributes.recipientNames = email.recipients.map(\.name)
                    attributes.recipientEmailAddresses = email.recipients.map(\.email)
                }
                activity.contentAttributeSet = attributes
                activity.userInfo = ["messageId": email.gmailMessageID ?? "", "accountID": coordinator.navigation.accountID]
            }
            .onContinueUserActivity("com.vikingz.vik.viewEmail") { activity in
                if let accountID = activity.userInfo?["accountID"] as? String,
                   !accountID.isEmpty,
                   coordinator.navigation.selectedAccountID != accountID {
                    coordinator.navigation.selectedAccountID = accountID
                }
                guard let messageId = activity.userInfo?["messageId"] as? String,
                      !messageId.isEmpty,
                      let email = coordinator.mailboxViewModel.emails.first(where: { $0.gmailMessageID == messageId })
                else { return }
                coordinator.selection.selectedEmail = email
                coordinator.selection.selectedEmailIDs = [messageId]
            }
            .userActivity("com.vikingz.vik.composeEmail", isActive: coordinator.isComposeActive) { activity in
                activity.title = "Composing email"
                activity.isEligibleForHandoff = true
            }

            KeyboardShortcutsView(coordinator: coordinator)

            UnifiedToastLayer()
                .zIndex(5)

            SlidePanelsWrapper(
                coordinator: coordinator,
                commandPalette: commandPalette,
                commandPaletteNamespace: commandPaletteNamespace
            )
        }
        .onChange(of: coordinator.calendar.calendarNewEventTrigger) { _, triggered in
            guard triggered else { return }
            coordinator.calendar.calendarNewEventTrigger = false
            newCalendarEventDraft = nil
            showNewCalendarEvent = true
        }
        .sheet(isPresented: $showNewCalendarEvent) {
            if let calendarVM = coordinator.calendar.calendarViewModel {
                CalendarEventEditorView(
                    editDraft: $newCalendarEventDraft,
                    calendars: calendarVM.calendars,
                    defaultStartTime: newEventStartTime,
                    onSave: { input, calendarId, scope in
                        Task {
                            if let draft = newCalendarEventDraft {
                                try? await calendarVM.updateEvent(
                                    calendarId: draft.calendarId,
                                    eventId: draft.googleEventId,
                                    accountID: draft.accountID,
                                    etag: draft.etag,
                                    input: input
                                )
                            } else {
                                let id = calendarId ?? "primary"
                                try? await calendarVM.createEvent(input, calendarId: id, accountID: coordinator.navigation.accountID)
                            }
                        }
                        showNewCalendarEvent = false
                    },
                    onCancel: { showNewCalendarEvent = false }
                )
            }
        }
    }

    // MARK: - List + Detail Split

    private var listDetailSplit: some View {
        ListDetailSplitView(
            coordinator: coordinator,
            columnVisibility: $columnVisibility,
            appFocus: $appFocus,
            isSidebarCollapsed: isSidebarCollapsed
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation(VikAnimation.springDefault) {
                    isSidebarCollapsed.toggle()
                }
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.leading")
            }
            .buttonStyle(.glass)
            .help("Toggle Sidebar (\u{2318}\\)")
            .keyboardShortcut("\\", modifiers: .command)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: isSidebarCollapsed)
        }

        EmailToolbarItems(
            coordinator: coordinator,
            showSnoozePicker: $showSnoozePicker
        )
    }

    // MARK: - Observation Boundary Views

    /// Isolates the calendar/mail mode switch so `viewMode` changes
    /// don't invalidate the rest of `mainLayout`.
    private struct ModeContentView: View {
        let coordinator: AppCoordinator
        @Binding var columnVisibility: NavigationSplitViewVisibility
        var appFocus: FocusState<AppFocus?>.Binding
        let isSidebarCollapsed: Bool
        @Binding var showNewCalendarEvent: Bool
        @Binding var newCalendarEventDraft: EventEditDraft?
        @Binding var newEventStartTime: Date?
        let reduceMotion: Bool

        var body: some View {
            Group {
                if coordinator.calendar.viewMode == .calendar,
                   let calendarVM = coordinator.calendar.calendarViewModel {
                    CalendarContainer(
                        coordinator: coordinator,
                        calendarVM: calendarVM,
                        showNewCalendarEvent: $showNewCalendarEvent,
                        newCalendarEventDraft: $newCalendarEventDraft,
                        newEventStartTime: $newEventStartTime
                    )
                    .transition(.opacity)
                } else {
                    ListDetailSplitView(
                        coordinator: coordinator,
                        columnVisibility: $columnVisibility,
                        appFocus: appFocus,
                        isSidebarCollapsed: isSidebarCollapsed
                    )
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : VikAnimation.folderSwitch, value: coordinator.calendar.viewMode)
        }
    }

    /// Isolates `SlidePanelsOverlay` and command palette reads from `mainLayout`.
    private struct SlidePanelsWrapper: View {
        let coordinator: AppCoordinator
        let commandPalette: CommandPaletteViewModel
        let commandPaletteNamespace: Namespace.ID

        var body: some View {
            @Bindable var navigation = coordinator.navigation
            ZStack {
                SlidePanelsOverlay(
                    panels: coordinator.panelCoordinator,
                    authViewModel: coordinator.authViewModel,
                    selectedAccountID: $navigation.selectedAccountID,
                    attachmentStore: coordinator.attachmentStore,
                    mailStore: coordinator.mailStore,
                    mailDatabase: coordinator.sync.mailDatabase,
                    attachmentIndexer: coordinator.sync.attachmentIndexer,
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
                    Color.black.opacity(OpacityToken.overlay)
                        .ignoresSafeArea()
                        .onTapGesture { commandPalette.dismiss() }
                        .zIndex(10)

                    CommandPaletteView(viewModel: commandPalette)
                        .matchedGeometryEffect(id: "commandPalette", in: commandPaletteNamespace)
                        .zIndex(11)
                        .transition(.opacity.combined(with: .scale(scale: ScaleToken.enterFrom)))
                }
            }
        }
    }

    /// Isolates list/detail navigation reads from `mainLayout` so changes
    /// to list-specific coordinator properties don't invalidate the parent.
    private struct ListDetailSplitView: View {
        let coordinator: AppCoordinator
        @Binding var columnVisibility: NavigationSplitViewVisibility
        var appFocus: FocusState<AppFocus?>.Binding
        let isSidebarCollapsed: Bool

        var body: some View {
            @Bindable var navigation = coordinator.navigation
            @Bindable var selection = coordinator.selection
            NavigationSplitView(columnVisibility: $columnVisibility) {
                if coordinator.navigation.selectedFolder == .attachments {
                    AttachmentExplorerView(
                        store: coordinator.attachmentStore,
                        panelCoordinator: coordinator.panelCoordinator,
                        accountID: coordinator.navigation.accountID,
                        onViewMessage: { messageId in
                            coordinator.navigateToMessage(gmailMessageID: messageId)
                        },
                        onDownloadAttachment: coordinator.downloadAttachment
                    )
                    .navigationTitle("Attachments")
                    .toolbar(removing: .sidebarToggle)
                } else {
                    ListPaneView(
                        emails: coordinator.selection.displayedEmails,
                        isLoading: coordinator.listIsLoading,
                        selectedFolder: $navigation.selectedFolder,
                        searchResetTrigger: coordinator.navigation.searchResetTrigger,
                        selectedEmail: $selection.selectedEmail,
                        selectedEmailIDs: $selection.selectedEmailIDs,
                        searchFocusTrigger: $navigation.searchFocusTrigger,
                        selectedLabel: coordinator.navigation.selectedLabel,
                        isSidebarCollapsed: isSidebarCollapsed,
                        actionCoordinator: coordinator.actionCoordinator,
                        mailboxViewModel: coordinator.mailboxViewModel,
                        selectedInboxCategory: $navigation.selectedInboxCategory,
                        selectNext: { coordinator.selection.selectNext($0) },
                        startCompose: { coordinator.startCompose(mode: $0) },
                        emptyTrashRequested: { coordinator.dialogs.emptyTrashRequested(count: $0) },
                        emptySpamRequested: { coordinator.dialogs.emptySpamRequested(count: $0) },
                        loadCurrentFolder: { await coordinator.loadCurrentFolder() }
                    )
                    .focused(appFocus, equals: .list)
                }
            } detail: {
                DetailPaneContainer(coordinator: coordinator)
                    .focused(appFocus, equals: .detail)
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    /// Isolates detail-pane reads (compose mode, signatures, contacts, mailDatabase,
    /// selectionDirection) from the list pane so those changes don't trigger list re-evaluation.
    private struct DetailPaneContainer: View {
        let coordinator: AppCoordinator

        var body: some View {
            if coordinator.navigation.selectedFolder != .attachments {
                DetailPaneView(
                    selectedEmail: coordinator.selection.selectedEmail,
                    selectedEmailIDs: coordinator.selection.selectedEmailIDs,
                    selectedFolder: coordinator.navigation.selectedFolder,
                    displayedEmails: coordinator.selection.displayedEmails,
                    actionCoordinator: coordinator.actionCoordinator,
                    mailboxViewModel: coordinator.mailboxViewModel,
                    mailStore: coordinator.mailStore,
                    accountID: coordinator.navigation.accountID,
                    fromAddress: coordinator.navigation.fromAddress,
                    composeMode: coordinator.compose.composeMode,
                    signatureForNew: coordinator.compose.signatureForNew,
                    signatureForReply: coordinator.compose.signatureForReply,
                    panelCoordinator: coordinator.panelCoordinator,
                    attachmentIndexer: coordinator.sync.attachmentIndexer,
                    contacts: coordinator.sync.contacts,
                    mailDatabase: coordinator.sync.mailDatabase,
                    selectNext: { coordinator.selection.selectNext($0) },
                    clearSelection: { coordinator.selection.clearSelection() },
                    deselectAll: { coordinator.selection.deselectAll() },
                    startCompose: { coordinator.startCompose(mode: $0) },
                    discardDraft: { coordinator.discardDraft(id: $0) },
                    selectionDirection: coordinator.selection.selectionDirection,
                    navigatePrevious: { coordinator.selection.selectPrevious() },
                    navigateNext: { coordinator.selection.selectNextEmail() },
                    switchToCalendar: { coordinator.navigateToEvent($0) }
                )
            }
        }
    }

    /// Isolates email-dependent toolbar items so `selectedEmail` changes
    /// don't re-evaluate the entire toolbar.
    private struct EmailToolbarItems: ToolbarContent {
        let coordinator: AppCoordinator
        @Binding var showSnoozePicker: Bool

        var body: some ToolbarContent {
            if !coordinator.panelCoordinator.isAnyOpen {
                ToolbarItem(placement: .primaryAction) {
                    Button { coordinator.composeNewEmail() } label: {
                        Label("Compose", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Compose (\u{2318}N)")
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)

                if let email = coordinator.selection.selectedEmail {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            coordinator.startCompose(mode: EmailDetailViewModel.replyMode(for: email))
                        } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left")
                        }
                        .buttonStyle(.glass)
                        .help("Reply")

                        if coordinator.navigation.selectedFolder != .archive {
                            Button {
                                Task { await coordinator.actionCoordinator.archiveEmail(email, selectNext: { coordinator.selection.selectNext($0) }) }
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .buttonStyle(.glass)
                            .help("Archive (\u{2318}E)")
                        }

                        if coordinator.navigation.selectedFolder != .trash {
                            Button {
                                Task { await coordinator.actionCoordinator.deleteEmail(email, selectNext: { coordinator.selection.selectNext($0) }) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .buttonStyle(.glass)
                            .help("Delete (\u{2318}\u{232B})")
                        }

                        Button {
                            showSnoozePicker = true
                        } label: {
                            Label("Snooze", systemImage: "clock")
                        }
                        .buttonStyle(.glass)
                        .help("Snooze")
                        .popover(isPresented: $showSnoozePicker) {
                            SnoozePickerView { date in
                                showSnoozePicker = false
                                Task { await coordinator.actionCoordinator.snoozeEmail(email, until: date, selectNext: { coordinator.selection.selectNext($0) }) }
                            }
                        }
                    }
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)

                if let email = coordinator.selection.selectedEmail {
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

                            if coordinator.navigation.selectedFolder == .archive || coordinator.navigation.selectedFolder == .trash {
                                Button {
                                    Task { await coordinator.actionCoordinator.moveToInboxEmail(email, selectedFolder: coordinator.navigation.selectedFolder, selectNext: { coordinator.selection.selectNext($0) }) }
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

                            if coordinator.navigation.selectedFolder == .spam {
                                Button {
                                    Task { await coordinator.actionCoordinator.markNotSpamEmail(email, selectNext: { coordinator.selection.selectNext($0) }) }
                                } label: { Label("Not Spam", systemImage: "tray.and.arrow.down") }
                            } else {
                                Button(role: .destructive) {
                                    Task { await coordinator.actionCoordinator.markSpamEmail(email, selectNext: { coordinator.selection.selectNext($0) }) }
                                } label: { Label("Report as Spam", systemImage: "exclamationmark.shield") }
                            }

                            if coordinator.navigation.selectedFolder == .trash {
                                Button(role: .destructive) {
                                    Task { await coordinator.actionCoordinator.deletePermanentlyEmail(email, selectNext: { coordinator.selection.selectNext($0) }) }
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
    }

    // MARK: - Lifecycle

    private func withLifecycle<V: View>(_ view: V) -> some View {
        view
            .modifier(LifecycleStateModifier(
                coordinator: coordinator,
                commandPalette: commandPalette,
                showSnoozePicker: $showSnoozePicker,
                snoozeCount: SnoozeStore.shared.count,
                scheduledCount: ScheduledSendStore.shared.count
            ))
            .modifier(LifecycleNotificationModifier(coordinator: coordinator))
            .task {
                for await notification in NotificationCenter.default.notifications(named: .calendarScopesInsufficient) {
                    calendarScopesAccountID = notification.userInfo?[CalendarAPIClient.accountIDKey] as? String
                    showCalendarScopesAlert = true
                }
            }
            .task {
                for await notification in NotificationCenter.default.notifications(named: .gmailScopesInsufficient) {
                    gmailScopesAccountID = notification.userInfo?[GmailAPIClient.accountIDKey] as? String
                    showGmailScopesAlert = true
                }
            }
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
                .onChange(of: coordinator.navigation.selectedFolder) { _, newValue in coordinator.handleFolderChange(newValue) }
                .onChange(of: coordinator.navigation.selectedInboxCategory) { _, newValue in coordinator.handleCategoryChange(newValue) }
                .onChange(of: coordinator.navigation.selectedLabel?.id) { _, _ in coordinator.handleLabelChange() }
                .onChange(of: coordinator.navigation.selectedAccountID) { _, newValue in coordinator.handleAccountChange(newValue) }
                .onChange(of: coordinator.authViewModel.accounts) { oldValue, newValue in coordinator.handleAccountsChange(old: oldValue, new: newValue) }
                .onChange(of: NetworkMonitor.shared.isConnected) { _, connected in
                    if connected {
                        OfflineActionQueue.shared.startDraining()
                        Task { await coordinator.sync.syncEngine?.triggerIncrementalSync() }
                        if let calendarEngine = coordinator.calendar.calendarSyncEngine {
                            Task {
                                await CalendarOfflineActionQueue.shared.processQueue(accountID: calendarEngine.accountID)
                                await calendarEngine.triggerSync()
                            }
                        }
                    }
                }
                .onChange(of: coordinator.selection.selectedEmail) { oldValue, newValue in
                    showSnoozePicker = false
                    // Track direction for directional detail pane transitions
                    if let newEmail = newValue, let oldEmail = oldValue {
                        if let newIdx = coordinator.selection.emailIndex(for: newEmail.id),
                           let oldIdx = coordinator.selection.emailIndex(for: oldEmail.id) {
                            coordinator.selection.selectionDirection = newIdx < oldIdx ? .top : .bottom
                        }
                    }
                    coordinator.handleSelectedEmailChange(newValue)
                }
                .onChange(of: coordinator.compose.signatureForNew) { _, _ in if !coordinator.navigation.accountID.isEmpty { coordinator.compose.saveSignatures(for: coordinator.navigation.accountID) } }
                .onChange(of: coordinator.compose.signatureForReply) { _, _ in if !coordinator.navigation.accountID.isEmpty { coordinator.compose.saveSignatures(for: coordinator.navigation.accountID) } }
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
                        coordinator.selection.selectedEmail = restoredEmail
                        coordinator.selection.selectedEmailIDs = [restoredEmail.id.uuidString]
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
                                    coordinator.navigation.selectedFolder = .inbox
                                    coordinator.navigation.searchFocusTrigger = true
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
                                       coordinator.navigation.selectedAccountID != accountID {
                                        coordinator.navigation.selectedAccountID = accountID
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
                                       coordinator.navigation.selectedAccountID != accountID {
                                        coordinator.navigation.selectedAccountID = accountID
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
                                       coordinator.navigation.selectedAccountID != accountID {
                                        coordinator.navigation.selectedAccountID = accountID
                                    }
                                    coordinator.navigateAndForward(gmailMessageID: messageId, recipient: recipient)
                                }
                            }
                        }
                        group.addTask {
                            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                                await coordinator.sync.syncEngine?.updatePollingInterval(appIsActive: true, windowIsKey: true)
                                await coordinator.calendar.calendarSyncEngine?.updatePollingInterval(
                                    calendarActive: coordinator.calendar.viewMode == .calendar,
                                    appFocused: true
                                )
                            }
                        }
                        group.addTask {
                            for await _ in NotificationCenter.default.notifications(named: NSApplication.didResignActiveNotification) {
                                await coordinator.sync.syncEngine?.updatePollingInterval(appIsActive: false, windowIsKey: false)
                                await coordinator.calendar.calendarSyncEngine?.updatePollingInterval(
                                    calendarActive: coordinator.calendar.viewMode == .calendar,
                                    appFocused: false
                                )
                            }
                        }
                    }
                }
        }
    }

    // MARK: - Sidebar Container

    private struct SidebarContainer: View {
        let coordinator: AppCoordinator
        @Binding var isSidebarCollapsed: Bool
        var appFocus: FocusState<AppFocus?>.Binding
        let sidebarWidth: CGFloat

        var body: some View {
            @Bindable var navigation = coordinator.navigation
            SidebarView(
                selectedFolder: $navigation.selectedFolder,
                selectedInboxCategory: $navigation.selectedInboxCategory,
                selectedLabel: $navigation.selectedLabel,
                selectedAccountID: $navigation.selectedAccountID,
                authViewModel: coordinator.authViewModel,
                isCollapsed: isSidebarCollapsed,
                userLabels: coordinator.mailboxViewModel.userLabels,
                viewMode: coordinator.calendar.viewMode,
                calendarViewModel: coordinator.calendar.calendarViewModel,
                miniAgendaEvents: coordinator.calendar.miniAgendaEvents,
                onSwitchToMail: { coordinator.calendar.switchToMail() },
                onSwitchToCalendar: { coordinator.calendar.switchToCalendar(db: coordinator.sync.mailDatabase) },
                onNavigateToEvent: { event in coordinator.calendar.navigateToEvent(event, db: coordinator.sync.mailDatabase) },
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
                onToggleSidebar: {
                    withAnimation(VikAnimation.springDefault) {
                        isSidebarCollapsed.toggle()
                    }
                },
                onShowDebug: {
                    coordinator.panelCoordinator.showDebug = true
                },
                onRefresh: {
                    Task { await coordinator.sync.syncEngine?.triggerIncrementalSync() }
                },
                onNewEvent: {
                    if let calendarVM = coordinator.calendar.calendarViewModel {
                        calendarVM.selectedDate = Date()
                    }
                    coordinator.switchToCalendar()
                }
            )
            .focused(appFocus, equals: .sidebar)
            .frame(width: sidebarWidth)
            .background(.regularMaterial)
        }
    }

    // MARK: - Calendar Container

    private struct CalendarContainer: View {
        let coordinator: AppCoordinator
        let calendarVM: CalendarViewModel
        @Binding var showNewCalendarEvent: Bool
        @Binding var newCalendarEventDraft: EventEditDraft?
        @Binding var newEventStartTime: Date?

        var body: some View {
            CalendarContainerView(
                viewModel: calendarVM,
                onNewEvent: {
                    newCalendarEventDraft = nil
                    newEventStartTime = nil
                    showNewCalendarEvent = true
                },
                onSelectEvent: { event in
                    calendarVM.selectedEvent = event
                },
                onCreateEvent: { date, hour in
                    calendarVM.selectedDate = date
                    newCalendarEventDraft = nil
                    var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
                    comps.hour = hour
                    newEventStartTime = Calendar.current.date(from: comps)
                    showNewCalendarEvent = true
                },
                onEdit: { event in
                    calendarVM.selectedEvent = nil
                    newCalendarEventDraft = EventEditDraft(from: event)
                    showNewCalendarEvent = true
                },
                onDelete: { event in
                    calendarVM.selectedEvent = nil
                    Task { try? await calendarVM.deleteEvent(event) }
                },
                onRSVP: { event, status in
                    Task { try? await calendarVM.respondToEvent(event, status: status) }
                },
                onEmailAttendees: { event in
                    CalendarEventQuickActions.emailAttendees(event: event) { mode in
                        coordinator.startCompose(mode: mode)
                    }
                },
                composeTo: { email in
                    coordinator.startCompose(mode: .newTo(to: email))
                },
                searchSender: { email in
                    Task { await coordinator.mailboxViewModel.search(query: "from:\(email)") }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}
