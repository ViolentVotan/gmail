import SwiftUI

@Observable
@MainActor
final class AppCoordinator {

    // MARK: - Child ViewModels

    let mailStore: MailStore
    let authViewModel: AuthViewModel
    let mailboxViewModel: MailboxViewModel
    let actionCoordinator: EmailActionCoordinator
    let panelCoordinator = PanelCoordinator()
    let attachmentStore: AttachmentStore

    private(set) var mailDatabase: MailDatabase?
    private(set) var backgroundSyncer: BackgroundSyncer?
    private var pendingDraftSelection: Email?
    private var lifecycleTask: Task<Void, Never>?
    private var cachedSnoozedEmails: [Email] = []
    private var cachedScheduledEmails: [Email] = []

    // MARK: - Selection State

    var selectedAccountID: String?
    var selectedFolder: Folder = .inbox
    var selectedInboxCategory: InboxCategory? = .all
    var selectedLabel: GmailLabel?
    var selectedEmail: Email?
    var selectedEmailIDs: Set<String> = []

    // MARK: - UI State

    var searchResetTrigger = 0
    var searchFocusTrigger = false
    var composeMode: ComposeMode = .new
    var signatureForNew: String = ""
    var signatureForReply: String = ""
    var lastRefreshedAt: Date?
    var showEmptyTrashConfirm = false
    var trashTotalCount = 0
    var showEmptySpamConfirm = false
    var spamTotalCount = 0
    var attachmentIndexer: AttachmentIndexer?

    // MARK: - AppStorage

    var undoDuration: Int = { let v = UserDefaults.standard.integer(forKey: UserDefaultsKey.undoDuration); return v != 0 ? v : 5 }() {
        didSet { UserDefaults.standard.set(undoDuration, forKey: UserDefaultsKey.undoDuration) }
    }
    var refreshInterval: Int = { let v = UserDefaults.standard.integer(forKey: UserDefaultsKey.refreshInterval); return v != 0 ? v : 120 }() {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: UserDefaultsKey.refreshInterval) }
    }

    // MARK: - Init

    init() {
        let store = MailStore()
        let vm = MailboxViewModel(accountID: "")
        self.mailStore = store
        self.mailboxViewModel = vm
        self.authViewModel = AuthViewModel()
        self.actionCoordinator = EmailActionCoordinator(mailboxViewModel: vm, mailStore: store)
        self.attachmentStore = AttachmentStore(database: .shared)
    }

    // MARK: - Computed Properties

    var accountID: String {
        selectedAccountID ?? authViewModel.primaryAccount?.id ?? ""
    }

    var displayedEmails: [Email] {
        if selectedFolder == .drafts { return mailStore.emails(for: .drafts) }
        if selectedFolder == .subscriptions { return SubscriptionsStore.shared.entries }
        if selectedFolder == .snoozed { return cachedSnoozedEmails }
        if selectedFolder == .scheduled { return cachedScheduledEmails }
        return mailboxViewModel.emails
    }

    var listIsLoading: Bool {
        selectedFolder == .subscriptions ? SubscriptionsStore.shared.isAnalyzing
        : selectedFolder == .drafts ? mailStore.isLoadingGmailDrafts
        : mailboxViewModel.isLoading
    }

    var isComposeActive: Bool {
        selectedFolder == .drafts && selectedEmail != nil
    }

    var fromAddress: String {
        authViewModel.primaryAccount?.email ?? ""
    }

    private func refreshSnoozedCache() {
        cachedSnoozedEmails = SnoozeStore.shared.items.map { item in
            Email(
                sender: Contact(name: item.senderName, email: ""),
                subject: item.subject,
                body: "",
                date: item.snoozeUntil,
                isRead: true,
                folder: .snoozed,
                gmailMessageID: item.messageId,
                gmailThreadID: item.threadId,
                gmailLabelIDs: item.originalLabelIds
            )
        }
    }

    private func refreshScheduledCache() {
        cachedScheduledEmails = ScheduledSendStore.shared.items.map { item in
            Email(
                sender: Contact(name: fromAddress, email: fromAddress),
                recipients: item.recipients.map { Contact(name: $0, email: $0) },
                subject: item.subject,
                body: "",
                date: item.scheduledTime,
                isRead: true,
                folder: .scheduled,
                isDraft: true
            )
        }
    }

    // MARK: - Actions

    func selectNext(_ email: Email?) {
        selectedEmail = email
    }

    func clearSelection() {
        selectedEmail = nil
        selectedEmailIDs = []
    }

    func deselectAll() {
        selectedEmailIDs = []
    }

    func emptyTrashRequested(count: Int) {
        trashTotalCount = count
        showEmptyTrashConfirm = true
    }

    func emptySpamRequested(count: Int) {
        spamTotalCount = count
        showEmptySpamConfirm = true
    }

    func renameLabel(_ label: GmailLabel, to newName: String) async {
        await mailboxViewModel.renameLabel(label, to: newName)
        if selectedLabel?.id == label.id {
            selectedLabel = mailboxViewModel.labels.first { $0.id == label.id }
        }
    }

    func deleteLabel(_ label: GmailLabel) async {
        await mailboxViewModel.deleteLabel(label)
        if selectedLabel?.id == label.id {
            selectedLabel = nil
            if selectedFolder == .labels {
                selectedLabel = mailboxViewModel.labels.filter { !$0.isSystemLabel }.first
            }
        }
    }

    func selectAllEmails() {
        selectedEmailIDs = Set(displayedEmails.map { $0.id.uuidString })
        selectedEmail = nil
    }

    func navigateToMessage(gmailMessageID: String) {
        Task {
            guard let msg = try? await GmailMessageService.shared.getMessage(
                id: gmailMessageID, accountID: accountID, format: "full"
            ) else { return }
            let email = mailboxViewModel.makeEmail(from: msg)
            panelCoordinator.showEmail(email, accountID: accountID)
        }
    }

    func composeNewEmail() {
        composeMode = .new
        let draft = mailStore.createDraft()
        if selectedFolder == .drafts {
            selectedEmail = draft
        } else {
            pendingDraftSelection = draft
            selectedFolder = .drafts
        }
    }

    func startCompose(mode: ComposeMode) {
        composeMode = mode
        let draft = mailStore.createDraft()
        if selectedFolder == .drafts {
            selectedEmail = draft
        } else {
            pendingDraftSelection = draft
            selectedFolder = .drafts
        }
    }

    func discardDraft(id: UUID) {
        composeMode = .new
        mailStore.deleteDraft(id: id)
        selectedEmail = nil
    }

    // MARK: - Per-Account Signatures

    func loadSignatures(for id: String) {
        signatureForNew = UserDefaults.standard.string(forKey: UserDefaultsKey.signatureForNew(id)) ?? ""
        signatureForReply = UserDefaults.standard.string(forKey: UserDefaultsKey.signatureForReply(id)) ?? ""
    }

    func saveSignatures(for id: String) {
        UserDefaults.standard.set(signatureForNew, forKey: UserDefaultsKey.signatureForNew(id))
        UserDefaults.standard.set(signatureForReply, forKey: UserDefaultsKey.signatureForReply(id))
    }

    // MARK: - Database Lifecycle

    private func setupDatabase(for accountID: String) async {
        do {
            let db = try await Task.detached(priority: .userInitiated) {
                let database = try MailDatabase(accountID: accountID)
                guard try database.integrityCheck() else {
                    MailDatabase.deleteDatabase(accountID: accountID)
                    return try MailDatabase(accountID: accountID)
                }
                return database
            }.value
            // Guard against account switching race
            guard self.selectedAccountID == accountID else { return }
            self.mailDatabase = db
            self.backgroundSyncer = BackgroundSyncer(db: db)
            if CacheMigration.needsMigration(accountID: accountID) {
                try? await CacheMigration.migrateIfNeeded(db: db, accountID: accountID)
                CacheMigration.cleanupOldCache()
            }
        } catch {
            print("Failed to create database for \(accountID): \(error)")
            self.mailDatabase = nil
            self.backgroundSyncer = nil
        }
    }

    // MARK: - Folder Loading

    func loadCurrentFolder() async {
        guard !mailboxViewModel.accountID.isEmpty else { return }
        switch selectedFolder {
        case .inbox:
            if let category = selectedInboxCategory {
                if category == .all {
                    await mailboxViewModel.refreshCurrentFolder(labelIDs: [GmailSystemLabel.inbox])
                } else {
                    await mailboxViewModel.refreshCurrentFolder(labelIDs: category.gmailLabelIDs)
                }
            } else {
                await mailboxViewModel.refreshCurrentFolder(labelIDs: [GmailSystemLabel.inbox])
            }
        case .labels:
            if let label = selectedLabel {
                await mailboxViewModel.refreshCurrentFolder(labelIDs: [label.id])
            }
        case .drafts:
            await mailStore.syncGmailDrafts(accountID: accountID)
        case .snoozed:
            refreshSnoozedCache()
        case .scheduled:
            refreshScheduledCache()
        case .subscriptions:
            break
        case .attachments:
            await mailboxViewModel.loadFolder(labelIDs: [], query: "has:attachment")
        default:
            if let labelID = selectedFolder.gmailLabelID {
                await mailboxViewModel.refreshCurrentFolder(labelIDs: [labelID])
            } else if let query = selectedFolder.gmailQuery {
                await mailboxViewModel.loadFolder(labelIDs: [], query: query)
            }
        }
    }

    // MARK: - Lifecycle Handlers

    func handleAppear() {
        if let account = authViewModel.primaryAccount {
            selectedAccountID = account.id
            mailboxViewModel.accountID = account.id
            mailStore.accountID = account.id
            SubscriptionsStore.shared.accountID = account.id
            attachmentStore.accountID = account.id
            loadSignatures(for: account.id)
            let indexer = AttachmentIndexer(
                database: .shared,
                messageService: GmailMessageService.shared,
                accountID: account.id
            )
            attachmentIndexer = indexer
            mailboxViewModel.attachmentIndexer = indexer
            Task {
                await setupDatabase(for: account.id)
                mailboxViewModel.setMailDatabase(self.mailDatabase)
                mailboxViewModel.setBackgroundSyncer(self.backgroundSyncer)
                await indexer.setProgressUpdate { [weak attachmentStore] in
                    Task { await attachmentStore?.refresh() }
                }
                async let folderLoad: Void = loadCurrentFolder()
                async let labelsLoad: Void = mailboxViewModel.loadLabels()
                async let sendAsLoad: Void = mailboxViewModel.loadSendAs()
                async let categoryLoad: Void = mailboxViewModel.loadCategoryUnreadCounts()
                async let photosLoad: Void = PeopleAPIService.shared.loadContactPhotos(accountID: account.id)
                _ = await (folderLoad, labelsLoad, sendAsLoad, categoryLoad, photosLoad)
                lastRefreshedAt = Date()
                await indexer.resumePending()
                await indexer.scanForAttachments()
                // Pre-fetch bodies at low priority after initial sync
                if let syncer = self.backgroundSyncer {
                    Task.detached(priority: .utility) {
                        try? await syncer.preFetchBodies(
                            messageService: GmailMessageService.shared,
                            accountID: account.id
                        )
                    }
                }
            }
        } else {
            selectedEmail = mailStore.emails(for: .inbox).first
        }
    }

    func handleFolderChange(_ folder: Folder) {
        if let pending = pendingDraftSelection {
            pendingDraftSelection = nil
            selectedEmail = pending
        } else {
            selectedEmail = nil
        }
        selectedEmailIDs = []
        searchResetTrigger += 1
        if folder != .labels { selectedLabel = nil }
        lifecycleTask?.cancel()
        if folder == .snoozed {
            refreshSnoozedCache()
        } else if folder == .scheduled {
            refreshScheduledCache()
        } else if folder == .attachments {
            lifecycleTask = Task {
                await attachmentStore.refresh()
                if let indexer = attachmentIndexer {
                    await indexer.scanForAttachments()
                }
            }
        } else if folder == .drafts {
            lifecycleTask = Task { await mailStore.syncGmailDrafts(accountID: accountID) }
        } else {
            lifecycleTask = Task { await loadCurrentFolder() }
        }
    }

    func handleLabelChange() {
        guard selectedFolder == .labels, selectedLabel != nil else { return }
        selectedEmail = nil
        selectedEmailIDs = []
        searchResetTrigger += 1
        lifecycleTask?.cancel()
        lifecycleTask = Task { await loadCurrentFolder() }
    }

    func handleCategoryChange(_ category: InboxCategory?) {
        selectedEmail = nil
        selectedEmailIDs = []
        searchResetTrigger += 1
        lifecycleTask?.cancel()
        lifecycleTask = Task { await loadCurrentFolder() }
    }

    func handleAccountChange(_ newID: String?) {
        guard let id = newID else { return }
        // Skip if handleAppear already set up this account
        guard mailboxViewModel.accountID != id else { return }
        // Save current account's signatures before switching
        let oldID = mailboxViewModel.accountID
        if !oldID.isEmpty { saveSignatures(for: oldID) }
        loadSignatures(for: id)
        selectedFolder = .inbox
        selectedInboxCategory = .all
        selectedLabel = nil
        selectedEmail = nil
        selectedEmailIDs = []
        searchResetTrigger += 1
        ThumbnailCache.shared.clearAll()
        mailStore.accountID = id
        SubscriptionsStore.shared.accountID = id
        attachmentStore.accountID = id
        let indexer = AttachmentIndexer(
            database: .shared,
            messageService: GmailMessageService.shared,
            accountID: id
        )
        attachmentIndexer = indexer
        mailboxViewModel.attachmentIndexer = indexer
        lifecycleTask?.cancel()
        lifecycleTask = Task {
            await attachmentStore.refresh()
            await setupDatabase(for: id)
            await indexer.setProgressUpdate { [weak attachmentStore] in
                Task { await attachmentStore?.refresh() }
            }
            await mailboxViewModel.switchAccount(id)
            mailboxViewModel.setMailDatabase(self.mailDatabase)
            mailboxViewModel.setBackgroundSyncer(self.backgroundSyncer)
            async let folderLoad: Void = loadCurrentFolder()
            async let labelsLoad: Void = mailboxViewModel.loadLabels()
            async let sendAsLoad: Void = mailboxViewModel.loadSendAs()
            async let categoryLoad: Void = mailboxViewModel.loadCategoryUnreadCounts()
            async let photosLoad: Void = PeopleAPIService.shared.loadContactPhotos(accountID: id)
            _ = await (folderLoad, labelsLoad, sendAsLoad, categoryLoad, photosLoad)
            await indexer.resumePending()
            await indexer.scanForAttachments()
        }
    }

    func handleAccountsChange(_ accounts: [GmailAccount]) {
        if selectedAccountID == nil, let first = accounts.first { selectedAccountID = first.id }
    }

    func handleSelectedEmailChange(_ email: Email?) {
        guard let email else { return }
        SpotlightIndexer.shared.indexEmail(email)
        guard let msgID = email.gmailMessageID,
              let message = mailboxViewModel.messages.first(where: { $0.id == msgID }),
              message.isUnread else { return }
        Task {
            await mailboxViewModel.markAsRead(message)
            await mailboxViewModel.loadCategoryUnreadCounts()
        }
    }
}
