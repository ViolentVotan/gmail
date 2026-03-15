import SwiftUI
private import os

@Observable
@MainActor
final class AppCoordinator {

    nonisolated private static let logger = Logger(subsystem: "com.vikingz.serif", category: "AppCoordinator")

    // MARK: - Child ViewModels

    let mailStore: MailStore
    let authViewModel: AuthViewModel
    let mailboxViewModel: MailboxViewModel
    let actionCoordinator: EmailActionCoordinator
    let panelCoordinator = PanelCoordinator()
    let syncProgressManager = SyncProgressManager()
    let attachmentStore: AttachmentStore

    private(set) var mailDatabase: MailDatabase?
    private(set) var backgroundSyncer: BackgroundSyncer?
    private(set) var syncEngine: FullSyncEngine?
    private var pendingDraftSelection: Email?
    private var lifecycleTask: Task<Void, Never>?
    private var markReadTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var cachedSnoozedEmails: [Email] = []
    private var cachedScheduledEmails: [Email] = []

    // MARK: - Selection State

    var selectedAccountID: String?
    var selectedFolder: Folder = .inbox
    var selectedInboxCategory: InboxCategory? = .all
    var selectedLabel: GmailLabel?
    var selectedEmail: Email?
    var selectedEmailIDs: Set<String> = []

    // MARK: - Contacts

    private(set) var contacts: [StoredContact] = []

    func loadContacts() {
        guard !accountID.isEmpty else { return }
        contacts = (try? MailDatabase.shared(for: accountID).dbPool.read { db in
            try MailDatabaseQueries.allContacts(in: db).map {
                StoredContact(name: $0.name ?? $0.email, email: $0.email, photoURL: $0.photoUrl)
            }
        }) ?? []
    }

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

    private(set) var displayedEmails: [Email] = []

    func recomputeDisplayedEmails() {
        if selectedFolder == .drafts {
            displayedEmails = mailStore.emails(for: .drafts)
        } else if selectedFolder == .subscriptions {
            displayedEmails = SubscriptionsStore.shared.entries
        } else if selectedFolder == .snoozed {
            displayedEmails = cachedSnoozedEmails
        } else if selectedFolder == .scheduled {
            displayedEmails = cachedScheduledEmails
        } else {
            let base = mailboxViewModel.emails
            if mailboxViewModel.priorityFilterEnabled {
                displayedEmails = base.filter { $0.gmailLabelIDs.contains(GmailSystemLabel.important) }
            } else {
                displayedEmails = base
            }
        }
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
        authViewModel.accounts.first(where: { $0.id == selectedAccountID })?.email
            ?? authViewModel.primaryAccount?.email
            ?? ""
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
        recomputeDisplayedEmails()
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
        recomputeDisplayedEmails()
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
        navigationTask?.cancel()
        let expectedAccountID = accountID
        navigationTask = Task {
            guard let msg = try? await GmailMessageService.shared.getMessage(
                id: gmailMessageID, accountID: expectedAccountID, format: "full"
            ) else { return }
            guard !Task.isCancelled, accountID == expectedAccountID else { return }
            let email = mailboxViewModel.makeEmail(from: msg)
            panelCoordinator.showEmail(email, accountID: expectedAccountID)
        }
    }

    func composeNewEmail(recipient: String? = nil) {
        composeMode = .new
        let draft = mailStore.createDraft()
        if let recipient, !recipient.isEmpty {
            mailStore.updateDraft(id: draft.id, subject: "", body: "", to: recipient, cc: "")
        }
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

    @concurrent
    private func openDatabase(for accountID: String) async throws -> MailDatabase {
        let database = try MailDatabase.shared(for: accountID)
        guard try database.integrityCheck() else {
            MailDatabase.deleteDatabase(accountID: accountID)
            return try MailDatabase.shared(for: accountID)
        }
        return database
    }

    private func setupDatabase(for accountID: String) async {
        do {
            let db = try await openDatabase(for: accountID)
            // Guard against account switching race
            guard self.selectedAccountID == accountID else { return }
            self.mailDatabase = db
            self.backgroundSyncer = BackgroundSyncer(db: db)
            if CacheMigration.needsMigration(accountID: accountID) {
                try? await CacheMigration.migrateIfNeeded(db: db, accountID: accountID)
                CacheMigration.cleanupOldCache()
            }
        } catch {
            Self.logger.error("Failed to create database for \(accountID): \(error)")
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
            SubscriptionsStore.shared.analyze(mailboxViewModel.emails)
        case .attachments:
            await mailboxViewModel.loadFolder(labelIDs: [], query: "has:attachment")
        default:
            if let labelID = selectedFolder.gmailLabelID {
                await mailboxViewModel.refreshCurrentFolder(labelIDs: [labelID])
            } else if let query = selectedFolder.gmailQuery {
                await mailboxViewModel.loadFolder(labelIDs: [], query: query)
            }
        }
        recomputeDisplayedEmails()
        // Trigger sync engine to check for new messages immediately
        await syncEngine?.triggerIncrementalSync()
        // Classify visible emails with Apple Intelligence (deduped via tagCache + DB)
        await EmailClassifier.shared.classifyBatch(mailboxViewModel.emails, db: mailDatabase)
    }

    // MARK: - Lifecycle Handlers

    func handleAppear() async {
        if let account = authViewModel.primaryAccount {
            selectedAccountID = account.id
            AccountStore.shared.selectedAccountID = account.id
            mailboxViewModel.accountID = account.id
            mailStore.accountID = account.id
            SubscriptionsStore.shared.accountID = account.id
            SummaryService.shared.accountID = account.id
            attachmentStore.accountID = account.id
            loadSignatures(for: account.id)
            await setupAccount(account.id)
            lastRefreshedAt = Date()
        } else {
            selectedEmail = mailStore.emails(for: .inbox).first
        }
    }

    // MARK: - Shared Account Setup

    private func setupAccount(_ id: String) async {
        let indexer = AttachmentIndexer(
            database: .shared,
            messageService: GmailMessageService.shared,
            accountID: id
        )
        attachmentIndexer = indexer
        mailboxViewModel.attachmentIndexer = indexer
        await setupDatabase(for: id)
        guard !Task.isCancelled, self.selectedAccountID == id else { return }
        mailboxViewModel.setMailDatabase(self.mailDatabase)
        mailboxViewModel.setBackgroundSyncer(self.backgroundSyncer)
        mailboxViewModel.setSyncProgressManager(self.syncProgressManager)
        // Start sync engine
        if let db = self.mailDatabase, let syncer = self.backgroundSyncer {
            let engine = FullSyncEngine(accountID: id, db: db, syncer: syncer)
            await engine.setProgressManager(self.syncProgressManager)
            self.syncEngine = engine
            await engine.start()
        }
        guard !Task.isCancelled, self.selectedAccountID == id else { return }
        await indexer.setProgressUpdate { [weak attachmentStore] in
            Task { await attachmentStore?.refresh() }
        }
        async let folderLoad: Void = loadCurrentFolder()
        async let labelsLoad: Void = mailboxViewModel.loadLabels()
        async let sendAsLoad: Void = mailboxViewModel.loadSendAs()
        async let categoryLoad: Void = mailboxViewModel.loadCategoryUnreadCounts()
        let syncerForPhotos = self.backgroundSyncer
        async let photosLoad: Void = {
            if let syncer = syncerForPhotos {
                await PeopleAPIService.shared.loadContactPhotos(accountID: id, syncer: syncer)
            }
        }()
        _ = await (folderLoad, labelsLoad, sendAsLoad, categoryLoad, photosLoad)
        guard !Task.isCancelled, self.selectedAccountID == id else { return }
        await indexer.resumePending()
        await indexer.scanForAttachments()
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
        recomputeDisplayedEmails()
        lifecycleTask?.cancel()
        if folder == .subscriptions {
            SubscriptionsStore.shared.analyze(mailboxViewModel.emails)
        } else if folder == .snoozed {
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
        // Save old account's signatures before switching
        let oldID = mailboxViewModel.accountID
        if !oldID.isEmpty { saveSignatures(for: oldID) }
        // Set immediately so any racing reads see the correct account
        mailboxViewModel.accountID = id
        // Keep AccountStore in sync so Settings scene can read the selected account
        AccountStore.shared.selectedAccountID = id
        loadSignatures(for: id)
        selectedFolder = .inbox
        selectedInboxCategory = .all
        selectedLabel = nil
        selectedEmail = nil
        selectedEmailIDs = []
        searchResetTrigger += 1
        navigationTask?.cancel()
        ThumbnailCache.shared.clearAll()
        mailStore.accountID = id
        SubscriptionsStore.shared.accountID = id
        attachmentStore.accountID = id
        // Reload per-account stores for the new account
        SnoozeStore.shared.load(accountID: id)
        ScheduledSendStore.shared.load(accountID: id)
        OfflineActionQueue.shared.load(accountID: id)
        loadContacts()
        recomputeDisplayedEmails()
        lifecycleTask?.cancel()
        lifecycleTask = Task {
            await attachmentStore.refresh()
            // Stop old sync engine
            await syncEngine?.stop()
            syncEngine = nil
            guard !Task.isCancelled, self.selectedAccountID == id else { return }
            syncProgressManager.reset()
            await mailboxViewModel.switchAccount(id)
            guard !Task.isCancelled, self.selectedAccountID == id else { return }
            SummaryService.shared.accountID = id
            await setupAccount(id)
        }
    }

    func handleAccountsChange(_ accounts: [GmailAccount]) {
        if selectedAccountID == nil, let first = accounts.first {
            selectedAccountID = first.id
        }
        // Stop engine if current account was removed (sign-out)
        if let id = selectedAccountID, !accounts.contains(where: { $0.id == id }) {
            lifecycleTask?.cancel()
            lifecycleTask = Task { await syncEngine?.stop() }
            syncEngine = nil
            mailDatabase = nil
            backgroundSyncer = nil
            selectedAccountID = accounts.first?.id
        }
    }

    // MARK: - Service Routing

    func handleQuickReply(messageId: String, text: String, accountID: String) async {
        guard let message = try? await GmailMessageService.shared.getMessage(
            id: messageId, accountID: accountID, format: "metadata"
        ) else { return }
        let replySubject = message.subject.hasPrefix("Re:") ? message.subject : "Re: \(message.subject)"
        _ = try? await GmailSendService.shared.send(
            from: accountID,
            to: [message.replyTo],
            subject: replySubject,
            body: text,
            threadID: message.threadId,
            referencesHeader: message.messageID,
            accountID: accountID
        )
        ToastManager.shared.show(message: "Reply sent")
    }

    @concurrent
    func downloadAttachment(messageID: String, attachmentID: String, accountID: String) async throws -> Data {
        try await GmailMessageService.shared.getAttachment(
            messageID: messageID, attachmentID: attachmentID, accountID: accountID
        )
    }

    func handleSelectedEmailChange(_ email: Email?) {
        guard let email else { return }
        SpotlightIndexer.shared.indexEmail(email)
        guard let msgID = email.gmailMessageID, !email.isRead else { return }
        markReadTask?.cancel()
        markReadTask = Task {
            await mailboxViewModel.markAsRead(msgID)
            guard !Task.isCancelled else { return }
            await mailboxViewModel.loadCategoryUnreadCounts()
        }
    }
}
