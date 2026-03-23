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
                        Task { await coordinator.actionCoordinator.emptyTrashFolder() }
                    }
                } message: {
                    Text("This will permanently delete \(coordinator.dialogs.trashTotalCount) message\(coordinator.dialogs.trashTotalCount == 1 ? "" : "s"). This action cannot be undone.")
                }
                .alert("Empty Spam", isPresented: $dialogs.showEmptySpamConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete All", role: .destructive) {
                        coordinator.selection.selectedEmail = nil
                        Task { await coordinator.actionCoordinator.emptySpamFolder() }
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
                .environment(coordinator.syncProgressManager)

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
                .zIndex(ZIndexToken.toast)

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
                withAnimation(reduceMotion ? nil : VikAnimation.springDefault) {
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

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    Color(nsColor: .windowBackgroundColor).opacity(OpacityToken.overlay)
                        .ignoresSafeArea()
                        .onTapGesture { commandPalette.dismiss() }
                        .zIndex(ZIndexToken.panel)

                    CommandPaletteView(viewModel: commandPalette)
                        .matchedGeometryEffect(id: "commandPalette", in: commandPaletteNamespace)
                        .zIndex(ZIndexToken.palette)
                        .transition(.opacity.combined(with: .scale(scale: ScaleToken.enterFrom)))
                }
            }
            .animation(reduceMotion ? nil : VikAnimation.springDefault, value: commandPalette.isVisible)
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
                        loadCurrentFolder: { await coordinator.loadCurrentFolder() },
                        selectedEmails: coordinator.selection.selectedEmails,
                        clearSelection: { coordinator.selection.clearSelection() }
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

    /// Isolates detail-pane reads from the list pane so changes in compose, sync, or
    /// selection sub-coordinators don't trigger list re-evaluation.
    /// Extracts all coordinator properties here and passes only values to sub-views.
    private struct DetailPaneContainer: View {
        let coordinator: AppCoordinator

        var body: some View {
            let selectedEmail = coordinator.selection.selectedEmail
            let selectedEmailIDs = coordinator.selection.selectedEmailIDs
            let selectedFolder = coordinator.navigation.selectedFolder

            if selectedFolder != .attachments {
                if selectedEmailIDs.count > 1 {
                    DetailBulkActionSection(
                        selectedEmailIDs: selectedEmailIDs,
                        selectedFolder: selectedFolder,
                        selectedEmails: coordinator.selection.selectedEmails,
                        actionCoordinator: coordinator.actionCoordinator,
                        mailboxViewModel: coordinator.mailboxViewModel,
                        mailStore: coordinator.mailStore,
                        panelCoordinator: coordinator.panelCoordinator,
                        clearSelection: { coordinator.selection.clearSelection() },
                        deselectAll: { coordinator.selection.deselectAll() }
                    )
                } else if let email = selectedEmail, email.isDraft {
                    DetailComposeSection(
                        selectedEmail: email,
                        selectedFolder: selectedFolder,
                        actionCoordinator: coordinator.actionCoordinator,
                        mailboxViewModel: coordinator.mailboxViewModel,
                        mailStore: coordinator.mailStore,
                        accountID: coordinator.navigation.accountID,
                        fromAddress: coordinator.navigation.fromAddress,
                        composeMode: coordinator.compose.composeMode,
                        signatureForNew: coordinator.compose.signatureForNew,
                        signatureForReply: coordinator.compose.signatureForReply,
                        panelCoordinator: coordinator.panelCoordinator,
                        contacts: coordinator.sync.contactsStore.contacts,
                        startCompose: { coordinator.startCompose(mode: $0) },
                        discardDraft: { coordinator.discardDraft(id: $0) }
                    )
                } else if selectedEmail != nil {
                    DetailEmailSection(
                        selectedEmail: selectedEmail,
                        selectedFolder: selectedFolder,
                        actionCoordinator: coordinator.actionCoordinator,
                        mailboxViewModel: coordinator.mailboxViewModel,
                        mailStore: coordinator.mailStore,
                        accountID: coordinator.navigation.accountID,
                        fromAddress: coordinator.navigation.fromAddress,
                        panelCoordinator: coordinator.panelCoordinator,
                        attachmentIndexer: coordinator.sync.attachmentIndexer,
                        contacts: coordinator.sync.contactsStore.contacts,
                        mailDatabase: coordinator.sync.mailDatabase,
                        selectionDirection: coordinator.selection.selectionDirection,
                        selectNext: { coordinator.selection.selectNext($0) },
                        clearSelection: { coordinator.selection.clearSelection() },
                        deselectAll: { coordinator.selection.deselectAll() },
                        startCompose: { coordinator.startCompose(mode: $0) },
                        navigatePrevious: { coordinator.selection.selectPrevious() },
                        navigateNext: { coordinator.selection.selectNextEmail() },
                        switchToCalendar: { coordinator.navigateToEvent($0) }
                    )
                } else {
                    DetailEmptySection()
                }
            }
        }
    }

    /// Observation-scoped view for bulk action bar.
    /// Accepts only the extracted values it needs — no coordinator reference.
    private struct DetailBulkActionSection: View {
        let selectedEmailIDs: Set<String>
        let selectedFolder: Folder
        let selectedEmails: [Email]
        let actionCoordinator: EmailActionCoordinator
        let mailboxViewModel: MailboxViewModel
        let mailStore: MailStore
        let panelCoordinator: PanelCoordinator
        let clearSelection: () -> Void
        let deselectAll: () -> Void

        var body: some View {
            DetailPaneView(
                selectedEmail: nil,
                selectedEmailIDs: selectedEmailIDs,
                selectedFolder: selectedFolder,
                selectedEmails: selectedEmails,
                actionCoordinator: actionCoordinator,
                mailboxViewModel: mailboxViewModel,
                allLabels: mailboxViewModel.labels,
                mailStore: mailStore,
                accountID: "",
                fromAddress: "",
                composeMode: .new,
                signatureForNew: "",
                signatureForReply: "",
                panelCoordinator: panelCoordinator,
                attachmentIndexer: nil,
                contacts: [],
                mailDatabase: nil,
                selectNext: { _ in },
                clearSelection: clearSelection,
                deselectAll: deselectAll,
                startCompose: { _ in },
                discardDraft: { _ in },
                selectionDirection: .bottom,
                navigatePrevious: {},
                navigateNext: {},
                switchToCalendar: nil
            )
        }
    }

    /// Observation-scoped view for compose mode.
    /// Accepts only the extracted values it needs — no coordinator reference.
    private struct DetailComposeSection: View {
        let selectedEmail: Email?
        let selectedFolder: Folder
        let actionCoordinator: EmailActionCoordinator
        let mailboxViewModel: MailboxViewModel
        let mailStore: MailStore
        let accountID: String
        let fromAddress: String
        let composeMode: ComposeMode
        let signatureForNew: String
        let signatureForReply: String
        let panelCoordinator: PanelCoordinator
        let contacts: [StoredContact]
        let startCompose: (ComposeMode) -> Void
        let discardDraft: (UUID) -> Void

        var body: some View {
            DetailPaneView(
                selectedEmail: selectedEmail,
                selectedEmailIDs: [],
                selectedFolder: selectedFolder,
                selectedEmails: [],
                actionCoordinator: actionCoordinator,
                mailboxViewModel: mailboxViewModel,
                allLabels: mailboxViewModel.labels,
                mailStore: mailStore,
                accountID: accountID,
                fromAddress: fromAddress,
                composeMode: composeMode,
                signatureForNew: signatureForNew,
                signatureForReply: signatureForReply,
                panelCoordinator: panelCoordinator,
                attachmentIndexer: nil,
                contacts: contacts,
                mailDatabase: nil,
                selectNext: { _ in },
                clearSelection: {},
                deselectAll: {},
                startCompose: startCompose,
                discardDraft: discardDraft,
                selectionDirection: .bottom,
                navigatePrevious: {},
                navigateNext: {},
                switchToCalendar: nil
            )
        }
    }

    /// Observation-scoped view for email detail.
    /// Accepts only the extracted values it needs — no coordinator reference.
    private struct DetailEmailSection: View {
        let selectedEmail: Email?
        let selectedFolder: Folder
        let actionCoordinator: EmailActionCoordinator
        let mailboxViewModel: MailboxViewModel
        let mailStore: MailStore
        let accountID: String
        let fromAddress: String
        let panelCoordinator: PanelCoordinator
        let attachmentIndexer: AttachmentIndexer?
        let contacts: [StoredContact]
        let mailDatabase: MailDatabase?
        let selectionDirection: Edge
        let selectNext: (Email?) -> Void
        let clearSelection: () -> Void
        let deselectAll: () -> Void
        let startCompose: (ComposeMode) -> Void
        let navigatePrevious: () -> Void
        let navigateNext: () -> Void
        let switchToCalendar: (CalendarEvent) -> Void

        var body: some View {
            DetailPaneView(
                selectedEmail: selectedEmail,
                selectedEmailIDs: [],
                selectedFolder: selectedFolder,
                selectedEmails: [],
                actionCoordinator: actionCoordinator,
                mailboxViewModel: mailboxViewModel,
                allLabels: mailboxViewModel.labels,
                mailStore: mailStore,
                accountID: accountID,
                fromAddress: fromAddress,
                composeMode: .new,
                signatureForNew: "",
                signatureForReply: "",
                panelCoordinator: panelCoordinator,
                attachmentIndexer: attachmentIndexer,
                contacts: contacts,
                mailDatabase: mailDatabase,
                selectNext: selectNext,
                clearSelection: clearSelection,
                deselectAll: deselectAll,
                startCompose: startCompose,
                discardDraft: { _ in },
                selectionDirection: selectionDirection,
                navigatePrevious: navigatePrevious,
                navigateNext: navigateNext,
                switchToCalendar: switchToCalendar
            )
        }
    }

    /// Observation-scoped empty state — reads nothing from the coordinator.
    private struct DetailEmptySection: View {
        var body: some View {
            ContentUnavailableView {
                Label("No Email Selected", systemImage: "envelope")
            } description: {
                Text("Select an email to view its contents.")
            }
            .navigationSplitViewColumnWidth(min: 500, ideal: 700)
        }
    }

    // MARK: - Lifecycle

    private func withLifecycle<V: View>(_ view: V) -> some View {
        view
            .modifier(LifecycleStateModifier(
                coordinator: coordinator,
                commandPalette: commandPalette,
                showSnoozePicker: $showSnoozePicker,
                appFocus: $appFocus,
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
            .task {
                coordinator.startPubSub()
            }
            .task {
                for await _ in NotificationCenter.default.notifications(named: NSApplication.willTerminateNotification) {
                    coordinator.stopPubSub()
                }
            }
    }

}
