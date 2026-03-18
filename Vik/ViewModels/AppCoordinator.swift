import SwiftUI
private import os

@Observable
@MainActor
final class AppCoordinator {

    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "AppCoordinator")

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
    private var pendingFolderChange: Folder?
    private var lifecycleTask: Task<Void, Never>?
    private var markReadTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var contactsTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cachedSnoozedEmails: [Email] = []
    private var cachedScheduledEmails: [Email] = []
    @ObservationIgnored private var accountSwitchGeneration = 0
    private var accountSwitchTask: Task<Void, Never>?

    // MARK: - Calendar State

    var viewMode: AppViewMode = .mail
    private(set) var calendarViewModel: CalendarViewModel?
    private(set) var calendarSyncEngine: CalendarSyncEngine?
    var miniAgendaEvents: [CalendarEvent] = []
    var calendarNewEventTrigger: Bool = false

    // MARK: - Selection State

    var selectedAccountID: String?
    var selectedFolder: Folder = .inbox
    var selectedInboxCategory: InboxCategory? = .all
    var selectedLabel: GmailLabel?
    var selectedEmail: Email?
    var selectedEmailIDs: Set<String> = []
    /// Direction of the last email selection for directional detail pane transitions.
    var selectionDirection: Edge = .bottom

    // MARK: - Contacts

    private(set) var contacts: [StoredContact] = []

    func loadContacts() {
        guard !accountID.isEmpty else { return }
        guard let db = mailDatabase else { return }
        let id = accountID
        contactsTask?.cancel()
        contactsTask = Task { [weak self] in
            let result = (try? await db.dbPool.read { db in
                try MailDatabaseQueries.allContacts(in: db).map {
                    StoredContact(name: $0.name ?? $0.email, email: $0.email, photoURL: $0.photoUrl)
                }
            }) ?? []
            guard !Task.isCancelled else { return }
            guard let self, self.accountID == id else { return }
            contacts = result
        }
    }

    // MARK: - UI State

    var searchResetTrigger = 0
    var searchFocusTrigger = false
    var composeMode: ComposeMode = .new
    var signatureForNew: String = ""
    var signatureForReply: String = ""
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
        vm.onEmailsChanged = { [weak self] in
            self?.updateDisplayedEmails()
        }
    }

    // MARK: - Computed Properties

    var accountID: String {
        selectedAccountID ?? authViewModel.primaryAccount?.id ?? ""
    }

    private(set) var displayedEmails: [Email] = []

    private func updateDisplayedEmails() {
        if selectedFolder == .drafts {
            displayedEmails = mailStore.emails(for: .drafts)
        } else if selectedFolder == .subscriptions {
            displayedEmails = SubscriptionsStore.shared.entries
        } else if selectedFolder == .snoozed {
            displayedEmails = cachedSnoozedEmails
        } else if selectedFolder == .scheduled {
            displayedEmails = cachedScheduledEmails
        } else if mailboxViewModel.priorityFilterEnabled {
            displayedEmails = mailboxViewModel.emails.filter { $0.gmailLabelIDs.contains(GmailSystemLabel.important) }
        } else {
            displayedEmails = mailboxViewModel.emails
        }
        // Keep selectedEmail fresh: replace with the updated version from the
        // new list so the detail pane reflects property changes (read, star, labels).
        if let selected = selectedEmail,
           let fresh = displayedEmails.first(where: { $0.id == selected.id }),
           fresh != selected {
            selectedEmail = fresh
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
                id: GmailDataTransformer.deterministicUUID(from: "snoozed-\(item.messageId)"),
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
        updateDisplayedEmails()
    }

    /// Called by ContentView's `.onChange` when `SnoozeStore.shared.items` changes.
    /// Only refreshes the cache if the snoozed folder is currently visible.
    func refreshSnoozedCacheIfNeeded() {
        guard selectedFolder == .snoozed else { return }
        refreshSnoozedCache()
    }

    /// Called by ContentView's `.onChange` when `ScheduledSendStore.shared.items` changes.
    /// Only refreshes the cache if the scheduled folder is currently visible.
    func refreshScheduledCacheIfNeeded() {
        guard selectedFolder == .scheduled else { return }
        refreshScheduledCache()
    }

    private func refreshScheduledCache() {
        cachedScheduledEmails = ScheduledSendStore.shared.items.map { item in
            Email(
                id: item.id,
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
        updateDisplayedEmails()
    }

    // MARK: - Actions

    func selectNext(_ email: Email?) {
        selectedEmail = email
    }

    /// Navigate to the previous email in the displayed list.
    func selectPrevious() {
        guard let current = selectedEmail,
              let idx = displayedEmails.firstIndex(where: { $0.id == current.id }),
              idx > 0 else { return }
        selectionDirection = .top
        let prev = displayedEmails[idx - 1]
        selectedEmail = prev
        selectedEmailIDs = [prev.id.uuidString]
    }

    /// Navigate to the next email in the displayed list.
    func selectNextEmail() {
        guard let current = selectedEmail,
              let idx = displayedEmails.firstIndex(where: { $0.id == current.id }),
              idx < displayedEmails.count - 1 else { return }
        selectionDirection = .bottom
        let next = displayedEmails[idx + 1]
        selectedEmail = next
        selectedEmailIDs = [next.id.uuidString]
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
        navigationTask = Task {
            _ = await fetchAndShowMessage(gmailMessageID: gmailMessageID)
        }
    }

    /// Navigates to a message and opens the reply compose sheet (from intent).
    func navigateAndReply(gmailMessageID: String, replyAll: Bool) {
        navigationTask?.cancel()
        navigationTask = Task {
            guard let (email, acctID) = await fetchAndShowMessage(gmailMessageID: gmailMessageID) else { return }
            let mode: ComposeMode = if replyAll {
                EmailDetailViewModel.replyAllMode(for: email, currentUserEmail: acctID)
            } else {
                EmailDetailViewModel.replyMode(for: email)
            }
            startCompose(mode: mode)
        }
    }

    /// Navigates to a message and opens the forward compose sheet (from intent).
    func navigateAndForward(gmailMessageID: String, recipient: String?) {
        navigationTask?.cancel()
        navigationTask = Task {
            guard let (email, _) = await fetchAndShowMessage(gmailMessageID: gmailMessageID) else { return }
            let mode = EmailDetailViewModel.forwardMode(for: email)
            startCompose(mode: mode)
        }
    }

    /// Fetches a Gmail message, converts it to an `Email`, and shows it in the preview panel.
    /// Returns `nil` if the fetch fails, the task is cancelled, or the account changed mid-flight.
    private func fetchAndShowMessage(gmailMessageID: String) async -> (Email, String)? {
        let expectedAccountID = accountID
        guard let msg = try? await GmailMessageService.shared.getMessage(
            id: gmailMessageID, accountID: expectedAccountID, format: "full"
        ) else { return nil }
        guard !Task.isCancelled, accountID == expectedAccountID else { return nil }
        let email = mailboxViewModel.makeEmail(from: msg)
        panelCoordinator.showEmail(email, accountID: expectedAccountID)
        return (email, expectedAccountID)
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
        mailStore.deleteDraft(id: id, accountID: accountID)
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
            syncProgressManager.syncFailed("Database error — restart app")
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
                // Lazy-load folders excluded from initial sync (spam, trash, etc.)
                await syncEngine?.syncFolderIfEmpty(labelId: labelID)
                await mailboxViewModel.refreshCurrentFolder(labelIDs: [labelID])
            } else if let query = selectedFolder.gmailQuery {
                await mailboxViewModel.loadFolder(labelIDs: [], query: query)
            }
        }
        updateDisplayedEmails()
        // Only show "synced just now" if initial sync has completed.
        // Otherwise the sync engine will report its own progress phases.
        let hasSynced = try? await mailDatabase?.dbPool.read { db in
            try MailDatabaseQueries.syncState(in: db)?.initialSyncComplete ?? false
        }
        if hasSynced == true {
            syncProgressManager.updateLastSynced()
        }
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
            loadContacts()
            await setupAccount(account.id)
            updateDisplayedEmails()
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
        await setupDatabase(for: id)
        guard !Task.isCancelled, self.selectedAccountID == id else { return }
        guard self.mailDatabase != nil else {
            // setupDatabase already reported the error to syncProgressManager
            return
        }
        mailboxViewModel.setMailDatabase(self.mailDatabase)
        mailboxViewModel.setBackgroundSyncer(self.backgroundSyncer)
        mailboxViewModel.setSyncProgressManager(self.syncProgressManager)
        // Stop any zombie engine left from a previous window (red X → reopen)
        await FullSyncEngine.stopActive(for: id)
        // Start sync engine
        if let db = self.mailDatabase, let syncer = self.backgroundSyncer {
            let progressManager = self.syncProgressManager
            let engine = FullSyncEngine(
                accountID: id, db: db, syncer: syncer,
                api: GmailMessageService.shared
            ) { @MainActor event in
                switch event {
                case .started: progressManager.syncStarted()
                case .progress(let remaining): progressManager.syncProgress(remaining: remaining)
                case .initialProgress(let synced, let estimated): progressManager.initialSyncProgress(synced: synced, estimated: estimated)
                case .bodyPrefetch(let remaining): progressManager.bodyPrefetchProgress(remaining: remaining)
                case .completed: progressManager.syncCompleted()
                case .failed(let message): progressManager.syncFailed(message)
                }
            }
            // Guard AFTER engine creation but BEFORE assignment to avoid orphaning
            // a running engine if the account switched during setup.
            guard !Task.isCancelled, self.selectedAccountID == id else { return }
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
        async let calendarLoad: Void = startCalendarSync(for: id)
        async let agendaLoad: Void = loadMiniAgendaEvents()
        let syncerForPhotos = self.backgroundSyncer
        async let photosLoad: Void = {
            if let syncer = syncerForPhotos {
                await PeopleAPIService.shared.loadContactPhotos(accountID: id, syncer: syncer)
            }
        }()
        _ = await (folderLoad, labelsLoad, sendAsLoad, categoryLoad, calendarLoad, agendaLoad, photosLoad)
        guard !Task.isCancelled, self.selectedAccountID == id else { return }
        await indexer.resumePending()
        await indexer.scanForAttachments()
    }

    func handleFolderChange(_ folder: Folder) {
        if accountSwitchTask != nil {
            pendingFolderChange = folder
            return
        }
        pendingFolderChange = nil
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
            lifecycleTask = Task {
                await mailStore.syncGmailDrafts(accountID: accountID)
                updateDisplayedEmails()
            }
        } else {
            lifecycleTask = Task { await loadCurrentFolder() }
        }
        updateDisplayedEmails()
    }

    func handleLabelChange() {
        guard selectedFolder == .labels, selectedLabel != nil else { return }
        selectedEmail = nil
        selectedEmailIDs = []
        searchResetTrigger += 1
        lifecycleTask?.cancel()
        lifecycleTask = Task { await loadCurrentFolder() }
        updateDisplayedEmails()
    }

    func handleCategoryChange(_ category: InboxCategory?) {
        selectedEmail = nil
        selectedEmailIDs = []
        searchResetTrigger += 1
        lifecycleTask?.cancel()
        lifecycleTask = Task { await loadCurrentFolder() }
        updateDisplayedEmails()
    }

    func handleAccountChange(_ newID: String?) {
        guard let id = newID else { return }
        // Skip if handleAppear already set up this account
        guard mailboxViewModel.accountID != id else { return }
        accountSwitchGeneration += 1
        let generation = accountSwitchGeneration
        // Confirm any pending undo actions for the old account before switching
        UndoActionManager.shared.confirmAll()
        // Save old account's signatures before switching
        let oldID = mailboxViewModel.accountID
        if !oldID.isEmpty { saveSignatures(for: oldID) }
        // Set immediately so any racing reads see the correct account
        mailboxViewModel.accountID = id
        // Keep AccountStore in sync so Settings scene can read the selected account
        AccountStore.shared.selectedAccountID = id
        loadSignatures(for: id)
        withAnimation(VikAnimation.folderSwitch) {
            selectedFolder = .inbox
            selectedInboxCategory = .all
            selectedLabel = nil
            selectedEmail = nil
            selectedEmailIDs = []
            searchResetTrigger += 1
        }
        navigationTask?.cancel()
        ThumbnailCache.shared.clearAll()
        mailStore.accountID = id
        SubscriptionsStore.shared.accountID = id
        attachmentStore.accountID = id
        SummaryService.shared.accountID = id
        // Reload per-account stores for the new account
        SnoozeStore.shared.load(accountID: id)
        ScheduledSendStore.shared.load(accountID: id)
        OfflineActionQueue.shared.load(accountID: id)
        loadContacts()
        // Capture the old engines before cancelling, so stop is guaranteed
        // even if a third account switch cancels this task later
        let oldEngine = syncEngine
        let oldCalendarEngine = calendarSyncEngine
        syncEngine = nil
        calendarSyncEngine = nil
        calendarViewModel = nil
        viewMode = .mail
        lifecycleTask?.cancel()
        lifecycleTask = nil
        accountSwitchTask?.cancel()
        let task = Task {
            defer {
                if self.accountSwitchGeneration == generation {
                    accountSwitchTask = nil
                }
                if let folder = pendingFolderChange {
                    pendingFolderChange = nil
                    selectedFolder = folder
                    handleFolderChange(folder)
                }
            }
            await oldEngine?.stop()
            await oldCalendarEngine?.stop()
            await attachmentStore.refresh()
            guard !Task.isCancelled, self.accountSwitchGeneration == generation else { return }
            syncProgressManager.reset()
            await mailboxViewModel.switchAccount(id)
            guard !Task.isCancelled, self.accountSwitchGeneration == generation else { return }
            await setupAccount(id)
            updateDisplayedEmails()
        }
        accountSwitchTask = task
    }

    func handleAccountsChange(old: [GmailAccount], new accounts: [GmailAccount]) {
        if selectedAccountID == nil, let first = accounts.first {
            selectedAccountID = first.id
        }
        // Detect removed and added accounts
        let previousIDs = Set(old.map(\.id))
        let currentIDs = Set(accounts.map(\.id))
        let removedIDs = previousIDs.subtracting(currentIDs)
        let addedIDs = currentIDs.subtracting(previousIDs)

        // Load per-account stores for newly added accounts (mid-session sign-in)
        for addedID in addedIDs {
            SnoozeStore.shared.load(accountID: addedID)
            ScheduledSendStore.shared.load(accountID: addedID)
            OfflineActionQueue.shared.load(accountID: addedID)
        }

        // Clean up per-account state for all removed accounts
        for removedID in removedIDs {
            TokenStore.shared.delete(for: removedID)
            UnsubscribeService.shared.clearAccount(removedID)
            ContactStore.shared.deleteAccount(removedID)
            SnoozeStore.shared.deleteAccount(removedID)
            ScheduledSendStore.shared.deleteAccount(removedID)
            OfflineActionQueue.shared.deleteAccount(removedID)
            CalendarOfflineActionQueue.shared.deleteAccount(removedID)
            LabelSyncService.shared.clearETags(for: removedID)
            SubscriptionsStore.shared.deleteAccount(removedID)
            MailDatabase.evict(accountID: removedID)
            UserDefaults.standard.removeObject(forKey: UserDefaultsKey.signatureForNew(removedID))
            UserDefaults.standard.removeObject(forKey: UserDefaultsKey.signatureForReply(removedID))
            UserDefaults.standard.removeObject(forKey: UserDefaultsKey.attachmentExclusionRules(removedID))
            UserDefaults.standard.removeObject(forKey: "replyDrafts.\(removedID)")
            UserDefaults.standard.removeObject(forKey: "com.vikingz.vik.dbMigrationCompleted.\(removedID)")
        }
        // Only wipe Spotlight if ALL accounts are being removed.
        // deleteAllItems() calls CSSearchableIndex.deleteAllSearchableItems()
        // which is global — it would destroy entries for accounts still signed in.
        if removedIDs == previousIDs, !removedIDs.isEmpty {
            Task { await SpotlightIndexer.shared.deleteAllItems() }
        }
        if !removedIDs.isEmpty {
            SnoozeMonitor.shared.clearAllFailureCounts()
        }

        // Stop engines if current account was removed (sign-out)
        if let id = selectedAccountID, removedIDs.contains(id) {
            let engineToStop = syncEngine
            let calendarEngineToStop = calendarSyncEngine
            syncEngine = nil
            calendarSyncEngine = nil
            calendarViewModel = nil
            viewMode = .mail
            lifecycleTask?.cancel()
            lifecycleTask = Task {
                // Await engine stop BEFORE deleting DB files to prevent
                // writes to a deleted database.
                await engineToStop?.stop()
                await calendarEngineToStop?.stop()
                self.mailDatabase = nil
                self.backgroundSyncer = nil
            }
            SummaryService.shared.accountID = ""
            selectedAccountID = accounts.first?.id
        }

        // Stop sync engines and delete database/attachment files for all removed accounts.
        // The selected account's engine is stopped above via the syncEngine property;
        // non-selected accounts may still have active engines in FullSyncEngine.activeEngines.
        let idsToDelete = removedIDs
        let engineTask = lifecycleTask
        cleanupTask = Task {
            // Wait for selected-account engine stop (no-op if lifecycleTask is nil / different account)
            await engineTask?.value
            // Stop any remaining active engines for non-selected removed accounts
            for removedID in idsToDelete {
                await FullSyncEngine.stopActive(for: removedID)
            }
            for removedID in idsToDelete {
                MailDatabase.deleteDatabase(accountID: removedID)
                await AttachmentDatabase.shared.deleteByAccountID(removedID)
            }
        }
    }

    // MARK: - Service Routing

    func handleQuickReply(messageId: String, text: String, accountID: String) async {
        guard let message = try? await GmailMessageService.shared.getMessage(
            id: messageId, accountID: accountID, format: "metadata"
        ) else { return }
        let replySubject = message.subject.withReplyPrefix
        let references = GmailSendService.buildReferencesChain(
            parentReferences: message.header(named: "References"),
            parentMessageID: message.messageID
        )
        do {
            _ = try await GmailSendService.shared.send(
                from: accountID,
                to: [message.replyTo],
                subject: replySubject,
                body: text,
                threadID: message.threadId,
                inReplyTo: message.messageID,
                references: references,
                accountID: accountID
            )
            ToastManager.shared.show(message: "Reply sent")
        } catch {
            ToastManager.shared.show(message: "Failed to send reply", type: .error)
        }
    }

    @concurrent
    func downloadAttachment(messageID: String, attachmentID: String, accountID: String) async throws -> Data {
        try await GmailMessageService.shared.getAttachment(
            messageID: messageID, attachmentID: attachmentID, accountID: accountID
        )
    }

    // MARK: - Preview Panel Actions

    /// Toggles star on a message (used by SlidePanelsOverlay preview panel).
    /// Routes through actionCoordinator for optimistic DB update + offline support.
    func previewToggleStar(messageID: String, isCurrentlyStarred: Bool, accountID: String) {
        guard let email = mailboxViewModel.emails.first(where: { $0.gmailMessageID == messageID }) else { return }
        Task { await actionCoordinator.toggleStarEmail(email) }
    }

    /// Marks a message as unread (used by SlidePanelsOverlay preview panel).
    /// Routes through actionCoordinator for optimistic DB update + offline support.
    func previewMarkUnread(messageID: String, accountID: String) {
        guard let email = mailboxViewModel.emails.first(where: { $0.gmailMessageID == messageID }) else { return }
        Task { await actionCoordinator.markUnreadEmail(email) }
    }

    func handleSelectedEmailChange(_ email: Email?) {
        guard let email else { return }
        Task { await SpotlightIndexer.shared.indexEmail(email) }
        guard let msgID = email.gmailMessageID, !email.isRead else { return }
        markReadTask?.cancel()
        markReadTask = Task {
            await mailboxViewModel.markAsRead(msgID)
            guard !Task.isCancelled else { return }
            await mailboxViewModel.loadCategoryUnreadCounts()
        }
    }

    // MARK: - Calendar Mode

    func switchToCalendar() {
        viewMode = .calendar
        if calendarViewModel == nil, let db = mailDatabase {
            calendarViewModel = CalendarViewModel(db: db)
            calendarViewModel?.startObserving()
        }
    }

    func switchToMail() {
        viewMode = .mail
    }

    func loadMiniAgendaEvents() async {
        guard let db = mailDatabase else { return }
        let id = accountID
        let records = (try? await db.dbPool.read { db in
            try MailDatabaseQueries.eventsForToday(accountId: id, in: db)
        }) ?? []
        guard !Task.isCancelled else { return }
        // Lightweight conversion — no attendees needed for mini-agenda
        miniAgendaEvents = records.map { $0.toCalendarEvent(attendees: [], calendarColor: BrandColor.blue) }
    }

    func navigateToEvent(_ event: CalendarEvent) {
        switchToCalendar()
        calendarViewModel?.selectedDate = event.startTime
        calendarViewModel?.selectedEvent = event
    }

    private func startCalendarSync(for id: String) async {
        guard let db = mailDatabase else { return }
        // Drain any calendar actions queued while offline before starting sync
        await CalendarOfflineActionQueue.shared.processQueue(accountID: id)
        let engine = CalendarSyncEngine(accountID: id, db: db)
        guard !Task.isCancelled, self.selectedAccountID == id else { return }
        calendarSyncEngine = engine
        await engine.start()
    }

    private func stopCalendarSync() async {
        await calendarSyncEngine?.stop()
        calendarSyncEngine = nil
        calendarViewModel = nil
    }

}
