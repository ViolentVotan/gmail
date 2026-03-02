import SwiftUI

struct ContentView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var mailStore = MailStore()
    @StateObject private var authViewModel = AuthViewModel()
    @StateObject private var mailboxViewModel = MailboxViewModel(accountID: "")
    @StateObject private var actionCoordinator: EmailActionCoordinator
    @ObservedObject private var subscriptionsStore = SubscriptionsStore.shared
    @State private var selectedAccountID: String?
    @State private var selectedFolder: Folder = .inbox
    @State private var selectedInboxCategory: InboxCategory? = .all
    @State private var selectedLabel: GmailLabel?
    @State private var selectedEmail: Email?
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var showDebug = false
    @State private var sidebarExpanded = false
    @State private var searchResetTrigger = 0
    @State private var composeMode: ComposeMode = .new
    @State private var showAttachmentPreview = false
    @State private var attachmentPreviewData: Data?
    @State private var attachmentPreviewName = ""
    @State private var attachmentPreviewFileType: Attachment.FileType = .document
    @State private var showOriginal = false
    @State private var originalMessage: GmailMessage?
    @State private var originalRawSource: String?
    @State private var isLoadingOriginal = false
    @AppStorage("undoDuration")        private var undoDuration:        Int = 5
    @AppStorage("refreshInterval")     private var refreshInterval:     Int = 120
    @AppStorage("signatureForNew")     private var signatureForNew:     String = ""
    @AppStorage("signatureForReply")   private var signatureForReply:   String = ""
    @State private var lastRefreshedAt: Date?
    @State private var showEmptyTrashConfirm = false
    @State private var trashTotalCount = 0
    @State private var selectedEmailIDs: Set<String> = []
    @State private var searchFocusTrigger = false

    init() {
        let store = MailStore()
        let vm = MailboxViewModel(accountID: "")
        _mailStore = StateObject(wrappedValue: store)
        _mailboxViewModel = StateObject(wrappedValue: vm)
        _actionCoordinator = StateObject(wrappedValue: EmailActionCoordinator(mailboxViewModel: vm, mailStore: store))
    }

    private var selectedEmails: [Email] {
        displayedEmails.filter { selectedEmailIDs.contains($0.id.uuidString) }
    }
    private var isMultiSelect: Bool { selectedEmailIDs.count > 1 }

    private var isEditingDraft: Bool {
        guard let email = selectedEmail else { return false }
        return email.isDraft && !email.isGmailDraft
    }

    private var isPanelOpen: Bool { showSettings || showHelp || showDebug || showAttachmentPreview || showOriginal }

    private func closePanel() {
        showSettings = false
        showHelp = false
        showDebug = false
        showAttachmentPreview = false
        showOriginal = false
    }

    // MARK: - Email source

    private var displayedEmails: [Email] {
        if selectedFolder == .drafts {
            return mailStore.emails(for: .drafts)
        }
        if selectedFolder == .subscriptions {
            return subscriptionsStore.entries
        }
        return mailboxViewModel.emails
    }

    // MARK: - Action helpers

    private func selectNext(_ email: Email?) { selectedEmail = email }
    private func clearSelection() { selectedEmail = nil; selectedEmailIDs = [] }

    private func selectAllEmails() {
        let allIDs = Set(displayedEmails.map { $0.id.uuidString })
        selectedEmailIDs = allIDs
        selectedEmail = nil
    }

    var body: some View {
        withLifecycle(
            mainLayout
                .environment(\.theme, themeManager.currentTheme)
                .preferredColorScheme(themeManager.currentTheme.isLight ? .light : .dark)
                .background(themeManager.currentTheme.detailBackground)
                .frame(minWidth: 900, minHeight: 600)
                .toolbar { toolbarContent }
                .alert("Empty Trash", isPresented: $showEmptyTrashConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete All", role: .destructive) {
                        selectedEmail = nil
                        Task { await mailboxViewModel.emptyTrash() }
                    }
                } message: {
                    Text("This will permanently delete \(trashTotalCount) message\(trashTotalCount == 1 ? "" : "s"). This action cannot be undone.")
                }
        )
    }

    private func withLifecycle<V: View>(_ view: V) -> some View {
        view
            .onAppear(perform: handleAppear)
            .onChange(of: selectedFolder, perform: handleFolderChange)
            .onChange(of: selectedInboxCategory, perform: handleCategoryChange)
            .onChange(of: selectedLabel?.id) { _ in handleLabelChange() }
            .onChange(of: selectedAccountID, perform: handleAccountChange)
            .onChange(of: authViewModel.accounts, perform: handleAccountsChange)
            .onChange(of: mailboxViewModel.messages.count, perform: handleMessagesCountChange)
            .onChange(of: selectedEmail, perform: handleSelectedEmailChange)
            .onChange(of: mailboxViewModel.lastRestoredMessageID) { msgID in
                guard let msgID else { return }
                mailboxViewModel.lastRestoredMessageID = nil
                if let restoredEmail = mailboxViewModel.emails.first(where: { $0.gmailMessageID == msgID }) {
                    selectedEmail = restoredEmail
                    selectedEmailIDs = [restoredEmail.id.uuidString]
                }
            }
            .onReceive(Timer.publish(every: TimeInterval(refreshInterval), on: .main, in: .common).autoconnect()) { _ in
                guard !mailboxViewModel.isLoading, !mailboxViewModel.accountID.isEmpty else { return }
                lastRefreshedAt = Date()
                Task {
                    await loadCurrentFolder()
                    await mailboxViewModel.loadCategoryUnreadCounts()
                }
            }
    }

    private func handleAppear() {
        if let account = authViewModel.primaryAccount {
            selectedAccountID = account.id
            mailboxViewModel.accountID = account.id
            Task {
                await loadCurrentFolder()
                await mailboxViewModel.loadLabels()
                await mailboxViewModel.loadSendAs()
                await mailboxViewModel.loadCategoryUnreadCounts()
                await GmailProfileService.shared.loadContactPhotos(accountID: account.id)
                lastRefreshedAt = Date()
            }
        } else {
            selectedEmail = mailStore.emails(for: .inbox).first
        }
    }

    private func handleFolderChange(_ folder: Folder) {
        selectedEmail = nil
        selectedEmailIDs = []
        searchResetTrigger += 1
        if folder != .labels { selectedLabel = nil }
        if folder == .drafts {
            let accountID = selectedAccountID ?? authViewModel.primaryAccount?.id ?? ""
            Task { await mailStore.syncGmailDrafts(accountID: accountID) }
        } else {
            Task { await loadCurrentFolder() }
        }
    }

    private func handleLabelChange() {
        guard selectedFolder == .labels, selectedLabel != nil else { return }
        selectedEmail = nil
        selectedEmailIDs = []
        searchResetTrigger += 1
        Task { await loadCurrentFolder() }
    }

    private func handleCategoryChange(_ category: InboxCategory?) {
        selectedEmail = nil
        selectedEmailIDs = []
        searchResetTrigger += 1
        Task { await loadCurrentFolder() }
    }

    private func handleAccountChange(_ newID: String?) {
        guard let id = newID else { return }
        selectedEmailIDs = []
        Task {
            await mailboxViewModel.switchAccount(id)
            await loadCurrentFolder()
            await mailboxViewModel.loadLabels()
            await mailboxViewModel.loadSendAs()
            await mailboxViewModel.loadCategoryUnreadCounts()
            await GmailProfileService.shared.loadContactPhotos(accountID: id)
        }
    }

    private func handleAccountsChange(_ accounts: [GmailAccount]) {
        if selectedAccountID == nil, let first = accounts.first { selectedAccountID = first.id }
    }

    private func handleMessagesCountChange(_ count: Int) { }

    private func handleSelectedEmailChange(_ email: Email?) {
        guard let email else { return }
        markAsReadIfNeeded(email)
    }

    private func markAsReadIfNeeded(_ email: Email) {
        guard let msgID = email.gmailMessageID,
              let message = mailboxViewModel.messages.first(where: { $0.id == msgID }),
              message.isUnread else { return }
        Task {
            await mailboxViewModel.markAsRead(message)
            await mailboxViewModel.loadCategoryUnreadCounts()
        }
    }

    private var mainLayout: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView(
                    selectedFolder: $selectedFolder,
                    selectedInboxCategory: $selectedInboxCategory,
                    selectedLabel: $selectedLabel,
                    selectedAccountID: $selectedAccountID,
                    showSettings: $showSettings,
                    isExpanded: $sidebarExpanded,
                    showHelp: $showHelp,
                    showDebug: $showDebug,
                    authViewModel: authViewModel,
                    categoryUnreadCounts: mailboxViewModel.categoryUnreadCounts,
                    userLabels: mailboxViewModel.labels.filter { !$0.isSystemLabel }
                )
                listPane
                Divider().background(themeManager.currentTheme.divider)
                detailPane.frame(minWidth: 400)
            }

            Button("") { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showSettings = true } }
                .keyboardShortcut(",", modifiers: .command).frame(width: 0, height: 0).opacity(0)

            Button("") { closePanel() }
                .keyboardShortcut(.escape, modifiers: []).frame(width: 0, height: 0).opacity(0).disabled(!isPanelOpen)

            Button("") { UndoActionManager.shared.undo() }
                .keyboardShortcut("z", modifiers: .command).frame(width: 0, height: 0).opacity(0)

            Button("") { searchFocusTrigger = true }
                .keyboardShortcut("f", modifiers: .command).frame(width: 0, height: 0).opacity(0)

            Button("") { selectAllEmails() }
                .keyboardShortcut("a", modifiers: .command).frame(width: 0, height: 0).opacity(0)

            OfflineToastView()
                .environment(\.theme, themeManager.currentTheme)
                .zIndex(4)

            UndoToastView()
                .environment(\.theme, themeManager.currentTheme)
                .zIndex(5)

            slidePanels
        }
    }

    @ViewBuilder
    private var slidePanels: some View {
        SlidePanel(isPresented: $showSettings, title: "Settings") {
            VStack(alignment: .leading, spacing: 16) {
                ThemePickerView(themeManager: themeManager)
                AccountsSettingsView(authViewModel: authViewModel, selectedAccountID: $selectedAccountID)
                BehaviorSettingsCard(
                    undoDuration: $undoDuration,
                    refreshInterval: $refreshInterval,
                    lastRefreshedAt: lastRefreshedAt
                )
                ContactsSettingsCard(
                    accountID: selectedAccountID ?? authViewModel.primaryAccount?.id ?? ""
                )
                SignatureSettingsCard(
                    aliases: mailboxViewModel.sendAsAliases,
                    signatureForNew: $signatureForNew,
                    signatureForReply: $signatureForReply
                )
            }
            .padding(20)
        }
        .environment(\.theme, themeManager.currentTheme)
        .zIndex(10)

        SlidePanel(isPresented: $showHelp, title: "Keyboard Shortcuts") {
            ShortcutsHelpView()
        }
        .environment(\.theme, themeManager.currentTheme)
        .zIndex(10)

        #if DEBUG
        SlidePanel(isPresented: $showDebug, title: "Debug") {
            DebugMenuView()
        }
        .environment(\.theme, themeManager.currentTheme)
        .zIndex(10)
        #endif

        SlidePanel(isPresented: $showOriginal, title: "Original Message") {
            if let msg = originalMessage {
                OriginalMessageView(
                    message: msg,
                    rawSource: originalRawSource,
                    isLoading: isLoadingOriginal
                )
            } else {
                VStack {
                    Spacer()
                    ProgressView()
                        .tint(themeManager.currentTheme.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.theme, themeManager.currentTheme)
        .zIndex(10)

        SlidePanel(isPresented: $showAttachmentPreview, title: attachmentPreviewName, scrollable: false) {
            if let data = attachmentPreviewData {
                AttachmentPreviewView(
                    data: data,
                    fileName: attachmentPreviewName,
                    fileType: attachmentPreviewFileType,
                    onDownload: { saveAttachment(data: data, name: attachmentPreviewName) },
                    onClose: { showAttachmentPreview = false }
                )
            } else {
                VStack {
                    Spacer()
                    ProgressView()
                        .tint(themeManager.currentTheme.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.theme, themeManager.currentTheme)
        .zIndex(10)
    }

    private func saveAttachment(data: Data, name: String) {
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { sidebarToggleButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { sidebarToggleButton }
        }

        if !isPanelOpen {
            ToolbarItem(placement: .primaryAction) {
                Button { composeNewEmail() } label: {
                    Image(systemName: "square.and.pencil").foregroundColor(themeManager.currentTheme.textPrimary)
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("Compose (⌘N)")
            }
        }
    }

    private var sidebarToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { sidebarExpanded.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(themeManager.currentTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Toggle sidebar")
        .opacity(isPanelOpen ? 0 : 1)
        .disabled(isPanelOpen)
    }

    // MARK: - List pane

    @ViewBuilder
    private var listPane: some View {
        if selectedFolder == .attachments {
            AttachmentsListView(
                mailboxViewModel: mailboxViewModel,
                selectedEmail: $selectedEmail
            )
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
        } else {
            EmailListView(
                emails: displayedEmails,
                isLoading: selectedFolder == .subscriptions ? subscriptionsStore.isAnalyzing
                         : selectedFolder == .drafts ? mailStore.isLoadingGmailDrafts
                         : mailboxViewModel.isLoading,
                onLoadMore: { Task { await mailboxViewModel.loadMore() } },
                onSearch: { query in
                    if query.isEmpty {
                        Task { await loadCurrentFolder() }
                    } else {
                        Task { await mailboxViewModel.search(query: query) }
                    }
                },
                onArchive:      { actionCoordinator.archiveEmail($0, selectNext: selectNext) },
                onDelete:       { actionCoordinator.deleteEmail($0, selectNext: selectNext) },
                onToggleStar:   { actionCoordinator.toggleStarEmail($0) },
                onMarkUnread:   { actionCoordinator.markUnreadEmail($0) },
                onMarkSpam:          { actionCoordinator.markSpamEmail($0, selectNext: selectNext) },
                onUnsubscribe:       { actionCoordinator.unsubscribeEmail($0) },
                onMoveToInbox:       { actionCoordinator.moveToInboxEmail($0, selectedFolder: selectedFolder, selectNext: selectNext) },
                onDeletePermanently: { actionCoordinator.deletePermanentlyEmail($0, selectNext: selectNext) },
                onMarkNotSpam:       { actionCoordinator.markNotSpamEmail($0, selectNext: selectNext) },
                onEmptyTrash:        { actionCoordinator.emptyTrash(accountID: selectedAccountID ?? authViewModel.primaryAccount?.id ?? "") { count in trashTotalCount = count; showEmptyTrashConfirm = true } },
                onBulkArchive:       { actionCoordinator.bulkArchive(selectedEmails, onClear: clearSelection) },
                onBulkDelete:        { actionCoordinator.bulkDelete(selectedEmails, onClear: clearSelection) },
                onBulkMarkUnread:    { actionCoordinator.bulkMarkUnread(selectedEmails) { selectedEmailIDs = [] } },
                onBulkMarkRead:      { actionCoordinator.bulkMarkRead(selectedEmails) { selectedEmailIDs = [] } },
                onBulkToggleStar:    { for e in selectedEmails { actionCoordinator.toggleStarEmail(e) } },
                onRefresh:           { await loadCurrentFolder() },
                searchResetTrigger: searchResetTrigger,
                searchFocusTrigger: $searchFocusTrigger,
                selectedEmail: $selectedEmail,
                selectedEmailIDs: $selectedEmailIDs,
                selectedFolder: $selectedFolder
            )
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if isMultiSelect {
            BulkActionBarView(
                count: selectedEmailIDs.count,
                selectedFolder: selectedFolder,
                onArchive:    { actionCoordinator.bulkArchive(selectedEmails, onClear: clearSelection) },
                onDelete:     { actionCoordinator.bulkDelete(selectedEmails, onClear: clearSelection) },
                onMarkUnread: { actionCoordinator.bulkMarkUnread(selectedEmails) { selectedEmailIDs = [] } },
                onMarkRead:   { actionCoordinator.bulkMarkRead(selectedEmails) { selectedEmailIDs = [] } },
                onToggleStar: { for e in selectedEmails { actionCoordinator.toggleStarEmail(e) } },
                onMoveToInbox: { actionCoordinator.bulkMoveToInbox(selectedEmails, selectedFolder: selectedFolder, onClear: clearSelection) },
                onDeselectAll: { selectedEmailIDs = [] }
            )
        } else if isEditingDraft, let draftId = selectedEmail?.id {
            ComposeView(
                mailStore: mailStore,
                draftId: draftId,
                accountID: selectedAccountID ?? authViewModel.primaryAccount?.id ?? "",
                fromAddress: authViewModel.primaryAccount?.email ?? "",
                mode: composeMode,
                sendAsAliases: mailboxViewModel.sendAsAliases,
                signatureForNew: signatureForNew,
                signatureForReply: signatureForReply,
                contacts: ContactStore.shared.contacts(for: selectedAccountID ?? authViewModel.primaryAccount?.id ?? ""),
                onDiscard: { discardDraft(id: draftId) }
            )
            .id(draftId)
        } else if let email = selectedEmail {
            EmailDetailView(
                email: email,
                accountID: selectedAccountID ?? authViewModel.primaryAccount?.id ?? "",
                onArchive:           selectedFolder == .archive ? nil : { actionCoordinator.archiveEmail(email, selectNext: selectNext) },
                onDelete:            selectedFolder == .trash   ? nil : { actionCoordinator.deleteEmail(email, selectNext: selectNext) },
                onMoveToInbox:       selectedFolder == .archive || selectedFolder == .trash ? { actionCoordinator.moveToInboxEmail(email, selectedFolder: selectedFolder, selectNext: selectNext) } : nil,
                onDeletePermanently: selectedFolder == .trash ? { actionCoordinator.deletePermanentlyEmail(email, selectNext: selectNext) } : nil,
                onMarkNotSpam:       selectedFolder == .spam ? { actionCoordinator.markNotSpamEmail(email, selectNext: selectNext) } : nil,
                onToggleStar: { isCurrentlyStarred in
                    guard let msgID = email.gmailMessageID else { return }
                    Task { await mailboxViewModel.toggleStar(msgID, isStarred: isCurrentlyStarred) }
                },
                onMarkUnread: { actionCoordinator.markUnreadEmail(email) },
                allLabels:    mailboxViewModel.labels,
                onAddLabel:   { labelID in
                    guard let msgID = email.gmailMessageID else { return }
                    Task { await mailboxViewModel.addLabel(labelID, to: msgID) }
                },
                onRemoveLabel: { labelID in
                    guard let msgID = email.gmailMessageID else { return }
                    Task { await mailboxViewModel.removeLabel(labelID, from: msgID) }
                },
                onReply:             { mode in startCompose(mode: mode) },
                onReplyAll:          { mode in startCompose(mode: mode) },
                onForward:           { mode in startCompose(mode: mode) },
                onCreateAndAddLabel: { name, completion in
                    guard let msgID = email.gmailMessageID else { completion(nil); return }
                    Task {
                        let labelID = await mailboxViewModel.createAndAddLabel(name: name, to: msgID)
                        completion(labelID)
                    }
                },
                onPreviewAttachment: { data, name, fileType in
                    attachmentPreviewData     = data
                    attachmentPreviewName     = name
                    attachmentPreviewFileType = fileType
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showAttachmentPreview = true
                    }
                },
                onShowOriginal: { vm in
                    guard let msg = vm.latestMessage else { return }
                    originalMessage = msg
                    originalRawSource = nil
                    isLoadingOriginal = true
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showOriginal = true
                    }
                    Task {
                        do {
                            let raw = try await GmailMessageService.shared.getRawMessage(id: msg.id, accountID: vm.accountID)
                            originalRawSource = raw.rawSource
                        } catch {
                            originalRawSource = nil
                        }
                        isLoadingOriginal = false
                    }
                },
                onDownloadMessage: { vm in
                    guard let msg = vm.latestMessage else { return }
                    Task {
                        do {
                            let raw = try await GmailMessageService.shared.getRawMessage(id: msg.id, accountID: vm.accountID)
                            if let source = raw.rawSource {
                                await MainActor.run {
                                    let panel = NSSavePanel()
                                    panel.nameFieldStringValue = "\(msg.subject).eml"
                                    panel.canCreateDirectories = true
                                    guard panel.runModal() == .OK, let url = panel.url else { return }
                                    try? source.data(using: .utf8)?.write(to: url)
                                }
                            }
                        } catch { }
                    }
                },
                onUnsubscribe: { url, oneClick, msgID in
                    await UnsubscribeService.shared.unsubscribe(url: url, oneClick: oneClick, messageID: msgID)
                },
                onPrint: { msg, email in
                    EmailPrintService.shared.printEmail(message: msg, email: email)
                },
                checkUnsubscribed: { msgID in
                    UnsubscribeService.shared.isUnsubscribed(messageID: msgID)
                },
                extractBodyUnsubscribeURL: { html in
                    UnsubscribeService.extractBodyUnsubscribeURL(from: html)
                }
            )
            .id(email.id)
        } else {
            emptyState
        }
    }

    // MARK: - Folder loading

    private func loadCurrentFolder() async {
        guard !mailboxViewModel.accountID.isEmpty else { return }
        switch selectedFolder {
        case .inbox:
            if let category = selectedInboxCategory {
                if category == .all {
                    await mailboxViewModel.loadFolder(labelIDs: ["INBOX"])
                } else {
                    await mailboxViewModel.loadFolder(labelIDs: category.gmailLabelIDs)
                }
            } else {
                await mailboxViewModel.loadFolder(labelIDs: ["INBOX"])
            }
        case .labels:
            if let label = selectedLabel {
                await mailboxViewModel.loadFolder(labelIDs: [label.id])
            }
        case .drafts:
            let accountID = selectedAccountID ?? authViewModel.primaryAccount?.id ?? ""
            await mailStore.syncGmailDrafts(accountID: accountID)
        case .subscriptions:
            break
        case .attachments:
            await mailboxViewModel.loadFolder(labelIDs: [], query: "has:attachment")
        default:
            if let labelID = selectedFolder.gmailLabelID {
                await mailboxViewModel.loadFolder(labelIDs: [labelID])
            } else if let query = selectedFolder.gmailQuery {
                await mailboxViewModel.loadFolder(labelIDs: [], query: query)
            }
        }
    }

    // MARK: - Compose

    private func composeNewEmail() {
        composeMode = .new
        let draft = mailStore.createDraft()
        selectedFolder = .drafts
        selectedEmail = draft
    }

    private func startCompose(mode: ComposeMode) {
        composeMode = mode
        let draft = mailStore.createDraft()
        selectedFolder = .drafts
        selectedEmail = draft
    }

    private func discardDraft(id: UUID) {
        composeMode = .new
        mailStore.deleteDraft(id: id)
        selectedEmail = nil
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.open")
                .font(.system(size: 40))
                .foregroundColor(themeManager.currentTheme.textTertiary)
            Text("Select an email to read")
                .font(.system(size: 14))
                .foregroundColor(themeManager.currentTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.currentTheme.detailBackground)
    }
}
