import SwiftUI

struct ContentView: View {
    @State private var appearanceManager = AppearanceManager()
    @State private var coordinator = AppCoordinator()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var commandPalette = CommandPaletteViewModel()

    enum AppFocus: Hashable {
        case sidebar
        case list
        case detail
    }

    @FocusState private var appFocus: AppFocus?

    // MARK: - Body

    var body: some View {
        withLifecycle(
            mainLayout
                .preferredColorScheme(appearanceManager.colorScheme)
                .frame(minWidth: 900, minHeight: 600)
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
                    userLabels: coordinator.mailboxViewModel.labels.filter { !$0.isSystemLabel },
                    onRenameLabel: { label, newName in Task { await coordinator.renameLabel(label, to: newName) } },
                    onDeleteLabel: { label in Task { await coordinator.deleteLabel(label) } }
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
                        onDownloadAttachment: { messageID, attachmentID, accountID in
                            try await GmailMessageService.shared.getAttachment(
                                messageID: messageID, attachmentID: attachmentID, accountID: accountID
                            )
                        }
                    )
                } else {
                    ListPaneView(
                        emails: coordinator.displayedEmails,
                        isLoading: coordinator.listIsLoading,
                        selectedFolder: $coordinator.selectedFolder,
                        searchResetTrigger: coordinator.searchResetTrigger,
                        selectedEmail: $coordinator.selectedEmail,
                        selectedEmailIDs: $coordinator.selectedEmailIDs,
                        searchFocusTrigger: $coordinator.searchFocusTrigger,
                        coordinator: coordinator
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
                        coordinator: coordinator
                    )
                    .focused($appFocus, equals: .detail)
                }
            }
            .backgroundExtensionEffect()
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
            .userActivity("com.genyus.serif.viewEmail", isActive: coordinator.selectedEmail != nil) { activity in
                guard let email = coordinator.selectedEmail else { return }
                activity.title = email.subject
                activity.isEligibleForHandoff = true
                activity.isEligibleForSearch = true
                activity.userInfo = [
                    "emailID": email.id.uuidString,
                    "threadID": email.gmailThreadID ?? "",
                    "accountID": coordinator.accountID
                ]
            }
            .onContinueUserActivity("com.genyus.serif.viewEmail") { activity in
                guard let emailID = activity.userInfo?["emailID"] as? String,
                      let uuid = UUID(uuidString: emailID),
                      let email = coordinator.mailboxViewModel.emails.first(where: { $0.id == uuid })
                else { return }
                coordinator.selectedEmail = email
                coordinator.selectedEmailIDs = [emailID]
            }
            .userActivity("com.genyus.serif.composeEmail", isActive: coordinator.isComposeActive) { activity in
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
                mailStore: coordinator.mailStore
            )

            if commandPalette.isVisible {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { commandPalette.dismiss() }
                    .zIndex(10)

                CommandPaletteView(viewModel: commandPalette)
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
                .controlSize(.large)
                .buttonStyle(.glassProminent)
                .help("Compose (\u{2318}N)")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            if let email = coordinator.selectedEmail {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        let vm = EmailDetailViewModel(accountID: coordinator.accountID)
                        coordinator.startCompose(mode: vm.replyMode(email: email))
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .help("Reply")

                    if coordinator.selectedFolder != .archive {
                        Button {
                            coordinator.actionCoordinator.archiveEmail(email, selectNext: { coordinator.selectNext($0) })
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .help("Archive (\u{2318}E)")
                    }

                    if coordinator.selectedFolder != .trash {
                        Button {
                            coordinator.actionCoordinator.deleteEmail(email, selectNext: { coordinator.selectNext($0) })
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .help("Delete (\u{2318}\u{232B})")
                    }
                }
            }

            if let email = coordinator.selectedEmail {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        let vm = EmailDetailViewModel(accountID: coordinator.accountID)
                        coordinator.startCompose(mode: vm.forwardMode(email: email))
                    } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    .help("Forward")

                    Button {
                        guard let msgID = email.gmailMessageID else { return }
                        let starred = coordinator.mailboxViewModel.messages.first(where: { $0.id == msgID })?.isStarred ?? email.isStarred
                        Task { await coordinator.mailboxViewModel.toggleStar(msgID, isStarred: starred) }
                    } label: {
                        let starred = coordinator.mailboxViewModel.messages.first(where: { $0.id == email.gmailMessageID })?.isStarred ?? email.isStarred
                        Label(starred ? "Unstar" : "Star", systemImage: starred ? "star.fill" : "star")
                    }
                    .help("Toggle Star (\u{2318}L)")

                    Button {
                        coordinator.actionCoordinator.markUnreadEmail(email)
                    } label: {
                        Label("Mark Unread", systemImage: "envelope.badge")
                    }
                    .help("Mark Unread (\u{21E7}\u{2318}U)")

                    Menu {
                        Button {
                            let vm = EmailDetailViewModel(accountID: coordinator.accountID)
                            coordinator.startCompose(mode: vm.replyAllMode(email: email))
                        } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }

                        if coordinator.selectedFolder == .archive || coordinator.selectedFolder == .trash {
                            Button {
                                coordinator.actionCoordinator.moveToInboxEmail(email, selectedFolder: coordinator.selectedFolder, selectNext: { coordinator.selectNext($0) })
                            } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
                        }

                        Divider()

                        Button {
                            if let msg = coordinator.mailboxViewModel.messages.first(where: { $0.id == email.gmailMessageID }) {
                                EmailPrintService.shared.printEmail(message: msg, email: email)
                            }
                        } label: { Label("Print", systemImage: "printer") }

                        Divider()

                        Button(role: .destructive) {
                            coordinator.actionCoordinator.markSpamEmail(email, selectNext: { coordinator.selectNext($0) })
                        } label: { Label("Report as Spam", systemImage: "exclamationmark.shield") }
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
            .onAppear {
                coordinator.handleAppear()
                commandPalette.buildCommands(coordinator: coordinator)
            }
            .onChange(of: coordinator.selectedFolder) { _, newValue in coordinator.handleFolderChange(newValue) }
            .onChange(of: coordinator.selectedInboxCategory) { _, newValue in coordinator.handleCategoryChange(newValue) }
            .onChange(of: coordinator.selectedLabel?.id) { _, _ in coordinator.handleLabelChange() }
            .onChange(of: coordinator.selectedAccountID) { _, newValue in coordinator.handleAccountChange(newValue) }
            .onChange(of: coordinator.authViewModel.accounts) { _, newValue in coordinator.handleAccountsChange(newValue) }
            .onChange(of: NetworkMonitor.shared.isConnected) { _, connected in
                if connected { OfflineActionQueue.shared.startDraining() }
            }
            .onChange(of: coordinator.selectedEmail) { _, newValue in coordinator.handleSelectedEmailChange(newValue) }
            .onChange(of: coordinator.signatureForNew) { _, _ in if !coordinator.accountID.isEmpty { coordinator.saveSignatures(for: coordinator.accountID) } }
            .onChange(of: coordinator.signatureForReply) { _, _ in if !coordinator.accountID.isEmpty { coordinator.saveSignatures(for: coordinator.accountID) } }
            .onReceive(NotificationCenter.default.publisher(for: .composeEmailFromIntent)) { _ in
                coordinator.composeNewEmail()
            }
            .onReceive(NotificationCenter.default.publisher(for: .searchEmailFromIntent)) { _ in
                coordinator.selectedFolder = .inbox
                coordinator.searchFocusTrigger = true
            }
            .onChange(of: coordinator.mailboxViewModel.lastRestoredMessageID) { _, msgID in
                guard let msgID else { return }
                coordinator.mailboxViewModel.lastRestoredMessageID = nil
                if let restoredEmail = coordinator.mailboxViewModel.emails.first(where: { $0.gmailMessageID == msgID }) {
                    coordinator.selectedEmail = restoredEmail
                    coordinator.selectedEmailIDs = [restoredEmail.id.uuidString]
                }
            }
            .onReceive(Timer.publish(every: TimeInterval(coordinator.refreshInterval), on: .main, in: .common).autoconnect()) { _ in
                guard !coordinator.mailboxViewModel.isLoading, !coordinator.mailboxViewModel.accountID.isEmpty else { return }
                coordinator.lastRefreshedAt = Date()
                Task {
                    await coordinator.loadCurrentFolder()
                    await coordinator.mailboxViewModel.loadCategoryUnreadCounts()
                }
            }
    }

}
