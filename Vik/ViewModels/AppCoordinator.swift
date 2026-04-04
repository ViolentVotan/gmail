import SwiftUI
private import os

@Observable
@MainActor
final class AppCoordinator {

    nonisolated private static let logger = Logger(category: "AppCoordinator")

    // MARK: - Sub-Coordinators

    let navigation: NavigationCoordinator
    let selection: SelectionCoordinator
    let compose: ComposeCoordinator
    let calendar: CalendarCoordinator
    let dialogs: DialogCoordinator
    let sync: SyncCoordinator

    // MARK: - Child ViewModels

    let mailStore: MailStore
    let authViewModel: AuthViewModel
    let mailboxViewModel: MailboxViewModel
    let actionCoordinator: EmailActionCoordinator
    let panelCoordinator = PanelCoordinator()
    let syncProgressManager = SyncProgressManager()
    let attachmentStore: AttachmentStore

    @ObservationIgnored private var navigationTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        let store = MailStore()
        let vm = MailboxViewModel(accountID: "")
        let auth = AuthViewModel()
        self.mailStore = store
        self.mailboxViewModel = vm
        self.authViewModel = auth
        self.actionCoordinator = EmailActionCoordinator(mailboxViewModel: vm, mailStore: store)
        self.attachmentStore = AttachmentStore(database: .shared)

        let nav = NavigationCoordinator(authViewModel: auth)
        let sel = SelectionCoordinator(mailboxViewModel: vm)
        let comp = ComposeCoordinator()
        let cal = CalendarCoordinator()
        let dlg = DialogCoordinator()
        let snc = SyncCoordinator()
        self.navigation = nav
        self.selection = sel
        self.compose = comp
        self.calendar = cal
        self.dialogs = dlg
        self.sync = snc

        vm.onEmailsChanged = { [weak self] in
            self?.updateDisplayedEmails()
        }
        snc.onCacheRefreshed = { [weak self] in
            self?.updateDisplayedEmails()
        }
        WebViewPool.shared.warmUp()
    }

    private static func replyDraftsKey(for accountID: String) -> String { "replyDrafts.\(accountID)" }
    private static func migrationKey(for accountID: String) -> String { "com.vikingz.vik.dbMigrationCompleted.\(accountID)" }

    isolated deinit {
        navigationTask?.cancel()
        sync.cancelAllTasks()
    }

    // MARK: - Cross-Domain Computed Properties

    var listIsLoading = false

    /// Recomputes `listIsLoading` from the currently selected folder's loading state.
    /// Call whenever the folder changes or a relevant loading flag changes.
    func updateListIsLoading() {
        let newValue: Bool = switch navigation.selectedFolder {
        case .subscriptions: SubscriptionsStore.shared.isAnalyzing
        case .drafts:        mailStore.isLoadingGmailDrafts
        default:             mailboxViewModel.isLoading
        }
        if listIsLoading != newValue { listIsLoading = newValue }
    }

    var isComposeActive: Bool {
        navigation.selectedFolder == .drafts && selection.selectedEmail != nil
    }

    // MARK: - Displayed Emails

    private func updateDisplayedEmails() {
        selection.updateDisplayedEmails(
            folder: navigation.selectedFolder,
            mailStore: mailStore,
            mailboxViewModel: mailboxViewModel,
            cachedSnoozedEmails: sync.snoozedEmails,
            cachedScheduledEmails: sync.scheduledEmails
        )
    }

    // MARK: - Convenience Actions (cross-coordinator parameter passing)

    func handleSelectedEmailChange(_ email: Email?) { selection.handleSelectedEmailChange(email) }

    func switchToCalendar() { calendar.switchToCalendar(db: sync.mailDatabase) }
    func switchToMail() { calendar.switchToMail() }
    func loadMiniAgendaEvents() async { await calendar.loadMiniAgendaEvents(db: sync.mailDatabase, accountID: navigation.accountID) }
    func navigateToEvent(_ event: CalendarEvent) { calendar.navigateToEvent(event, db: sync.mailDatabase) }

    func loadContacts() { sync.loadContacts(accountID: navigation.accountID) }

    func refreshSnoozedCacheIfNeeded() {
        sync.refreshSnoozedCacheIfNeeded(folder: navigation.selectedFolder, fromAddress: navigation.fromAddress)
    }

    func refreshScheduledCacheIfNeeded() {
        sync.refreshScheduledCacheIfNeeded(folder: navigation.selectedFolder, fromAddress: navigation.fromAddress)
    }

    // MARK: - Label Management

    func renameLabel(_ label: GmailLabel, to newName: String) async {
        await mailboxViewModel.renameLabel(label, to: newName)
        if navigation.selectedLabel?.id == label.id {
            navigation.selectedLabel = mailboxViewModel.labels.first { $0.id == label.id }
        }
    }

    func deleteLabel(_ label: GmailLabel) async {
        await mailboxViewModel.deleteLabel(label)
        if navigation.selectedLabel?.id == label.id {
            navigation.selectedLabel = nil
            if navigation.selectedFolder == .labels {
                navigation.selectedLabel = mailboxViewModel.labels.filter { !$0.isSystemLabel }.first
            }
        }
    }

    // MARK: - Navigation Actions

    func navigateToMessage(gmailMessageID: String) {
        navigationTask?.cancel()
        navigationTask = Task {
            _ = await fetchAndShowMessage(gmailMessageID: gmailMessageID)
        }
    }

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

    func navigateAndForward(gmailMessageID: String, recipient: String?) {
        navigationTask?.cancel()
        navigationTask = Task {
            guard let (email, _) = await fetchAndShowMessage(gmailMessageID: gmailMessageID) else { return }
            let mode = EmailDetailViewModel.forwardMode(for: email)
            if case .forward(_, let subject, let quotedBody) = mode, let recipient {
                startCompose(mode: .forward(to: recipient, subject: subject, quotedBody: quotedBody))
            } else {
                startCompose(mode: mode)
            }
        }
    }

    private func fetchAndShowMessage(gmailMessageID: String) async -> (Email, String)? {
        let expectedAccountID = navigation.accountID
        guard let msg = try? await GmailMessageService.shared.getMessage(
            id: gmailMessageID, accountID: expectedAccountID, format: "full"
        ) else { return nil }
        guard !Task.isCancelled, navigation.accountID == expectedAccountID else { return nil }
        let email = mailboxViewModel.makeEmail(from: msg)
        panelCoordinator.showEmail(email, accountID: expectedAccountID)
        return (email, expectedAccountID)
    }

    // MARK: - Compose Actions

    func composeNewEmail(recipient: String? = nil) {
        compose.composeMode = .new
        let draft = mailStore.createDraft()
        if let recipient, !recipient.isEmpty {
            Task { await mailStore.updateDraft(id: draft.id, subject: "", body: "", to: recipient, cc: "") }
        }
        if navigation.selectedFolder == .drafts {
            selection.selectedEmail = draft
        } else {
            compose.setPendingDraftSelection(draft)
            navigation.selectedFolder = .drafts
        }
    }

    func startCompose(mode: ComposeMode) {
        compose.composeMode = mode
        let draft = mailStore.createDraft()
        if navigation.selectedFolder == .drafts {
            selection.selectedEmail = draft
        } else {
            compose.setPendingDraftSelection(draft)
            navigation.selectedFolder = .drafts
        }
    }

    func discardDraft(id: UUID) {
        compose.composeMode = .new
        mailStore.deleteDraft(id: id, accountID: navigation.accountID)
        selection.selectedEmail = nil
    }

    // MARK: - Folder Loading

    func loadCurrentFolder() async {
        guard !mailboxViewModel.accountID.isEmpty else { return }
        switch navigation.selectedFolder {
        case .inbox:
            if let category = navigation.selectedInboxCategory {
                if category == .all {
                    await mailboxViewModel.refreshCurrentFolder(labelIDs: [GmailSystemLabel.inbox])
                } else {
                    await mailboxViewModel.refreshCurrentFolder(labelIDs: category.gmailLabelIDs)
                }
            } else {
                await mailboxViewModel.refreshCurrentFolder(labelIDs: [GmailSystemLabel.inbox])
            }
        case .labels:
            if let label = navigation.selectedLabel {
                await mailboxViewModel.refreshCurrentFolder(labelIDs: [label.id])
            }
        case .drafts:
            await mailStore.syncGmailDrafts(accountID: navigation.accountID)
        case .snoozed:
            sync.refreshSnoozedCache(fromAddress: navigation.fromAddress)
        case .scheduled:
            sync.refreshScheduledCache(fromAddress: navigation.fromAddress)
        case .subscriptions:
            SubscriptionsStore.shared.analyze(mailboxViewModel.emails)
        case .attachments:
            await mailboxViewModel.loadFolder(labelIDs: [], query: "has:attachment")
        default:
            if let labelID = navigation.selectedFolder.gmailLabelID {
                await sync.syncEngine?.syncFolderIfEmpty(labelId: labelID)
                await mailboxViewModel.refreshCurrentFolder(labelIDs: [labelID])
            } else if let query = navigation.selectedFolder.gmailQuery {
                await mailboxViewModel.loadFolder(labelIDs: [], query: query)
            }
        }
        updateDisplayedEmails()
        let hasSynced = try? await sync.mailDatabase?.dbPool.read { db in
            try MailDatabaseQueries.syncState(in: db)?.initialSyncComplete ?? false
        }
        if hasSynced == true {
            syncProgressManager.updateLastSynced()
        }
        await sync.syncEngine?.triggerIncrementalSync()
        await EmailClassifier.shared.classifyBatch(mailboxViewModel.emails, db: sync.mailDatabase)
    }

    // MARK: - Lifecycle Handlers

    func handleAppear() async {
        if let account = authViewModel.primaryAccount {
            navigation.selectedAccountID = account.id
            AccountStore.shared.selectedAccountID = account.id
            applyAccountID(account.id)
            compose.loadSignatures(for: account.id)
            await setupAccount(account.id)
            sync.loadContacts(accountID: account.id)
            updateDisplayedEmails()
        } else {
            selection.selectedEmail = mailStore.emails(for: .inbox).first
        }
    }

    /// Handles a message restored from undo (e.g. un-archive/un-delete).
    /// Clears the trigger and selects the restored email if found.
    func handleRestoredMessage(_ msgID: String) {
        mailboxViewModel.labelMutations.lastRestoredMessageID = nil
        if let restoredEmail = mailboxViewModel.emails.first(where: { $0.gmailMessageID == msgID }) {
            selection.selectedEmail = restoredEmail
            selection.selectedEmailIDs = [restoredEmail.id.uuidString]
        }
    }

    /// Handles network reconnection: drains offline queues and triggers sync.
    func handleNetworkReconnection() {
        OfflineActionQueue.shared.startDraining()
        Task { await sync.syncEngine?.triggerIncrementalSync() }
        if let calendarEngine = calendar.calendarSyncEngine {
            Task {
                await CalendarOfflineActionQueue.shared.processQueue(accountID: calendarEngine.accountID)
                await calendarEngine.triggerSync()
            }
        }
    }

    /// One-time Pub/Sub initialization on app launch.
    /// Skips entirely when the stored token lacks the `pubsub` scope (the token
    /// was issued before the scope was added — polling covers sync until the user
    /// reauthorizes for any reason).
    func startPubSub() {
        sync.pubSubTask = Task { [weak self] in
            guard let self else { return }
            let accounts = AccountStore.shared.accounts
            guard let first = accounts.first else { return }

            // Check that the token has the pubsub scope before making any API calls.
            // Tokens issued before the scope was added will not have it; refreshing
            // does not grant new scopes. Skip Pub/Sub silently — polling works fine.
            guard let token = await TokenStore.shared.retrieve(for: first.id),
                  token.hasScope("https://www.googleapis.com/auth/pubsub") else {
                return
            }

            // Register watches for ALL accounts
            for account in accounts {
                await sync.watchService.registerWatch(accountID: account.id)
            }

            // Start pull loop with first account's token
            await sync.pubSubService.start(tokenAccountID: first.id)

            // Start daily renewal
            await sync.watchService.startRenewalLoop(accountIDs: accounts.map(\.id))
        }
    }

    /// Stops all Pub/Sub watches and pull loop. Call on app termination.
    func stopPubSub() {
        Task {
            await sync.watchService.stopAll()
            await sync.pubSubService.stop()
        }
    }

    /// Stops Pub/Sub cleanly, then restarts it. Call after re-authorization
    /// grants the pubsub scope so that watches are re-registered and the
    /// pull loop starts with the new token.
    func restartPubSub() {
        sync.pubSubTask?.cancel()
        sync.pubSubTask = nil
        Task {
            await sync.watchService.stopAll()
            await sync.pubSubService.stop()
            startPubSub()
        }
    }

    /// Re-creates the sync engine for the current account after re-authorization.
    func restartSync(for accountID: String) async {
        guard navigation.selectedAccountID == accountID else { return }
        await setupAccount(accountID)
    }

    // MARK: - Shared Account Setup

    /// Propagates the given account ID to all services that need it.
    private func applyAccountID(_ id: String) {
        mailboxViewModel.accountID = id
        mailStore.accountID = id
        SubscriptionsStore.shared.accountID = id
        SummaryService.shared.accountID = id
        attachmentStore.accountID = id
    }

    private func setupAccount(_ id: String) async {
        let indexer = AttachmentIndexer(
            database: .shared,
            messageService: GmailMessageService.shared,
            accountID: id
        )
        sync.attachmentIndexer = indexer
        await sync.setupDatabase(for: id, selectedAccountID: navigation.selectedAccountID, syncProgressManager: syncProgressManager)
        guard !Task.isCancelled, navigation.selectedAccountID == id else { return }
        guard sync.mailDatabase != nil else { return }
        mailboxViewModel.setMailDatabase(sync.mailDatabase)
        mailboxViewModel.setBackgroundSyncer(sync.backgroundSyncer)
        mailboxViewModel.setSyncProgressManager(syncProgressManager)
        selection.accountID = id
        selection.mailDatabase = sync.mailDatabase
        await FullSyncEngine.stopActive(for: id)
        if let db = sync.mailDatabase, let syncer = sync.backgroundSyncer {
            let progressManager = syncProgressManager
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
            guard !Task.isCancelled, navigation.selectedAccountID == id else { return }
            sync.setSyncEngine(engine)
            await engine.start()

            // Wire Pub/Sub: set active engine and enable backup polling
            // Only enable if PubSub actually started (token had the pubsub scope).
            if await sync.pubSubService.tokenAccountID != nil {
                if let email = AccountStore.shared.accounts.first(where: { $0.id == id })?.email {
                    await sync.pubSubService.setActiveEngine(email: email, engine: engine)
                }
                await engine.setPubSubActive(true)
            }
        }
        guard !Task.isCancelled, navigation.selectedAccountID == id else { return }
        await indexer.setProgressUpdate { [weak self] in
            guard let self else { return }
            if navigation.selectedFolder == .attachments {
                Task { await attachmentStore.refresh() }
            } else {
                attachmentStore.setNeedsRefresh()
            }
        }
        async let folderLoad: Void = loadCurrentFolder()
        async let labelsLoad: Void = mailboxViewModel.loadLabels()
        async let sendAsLoad: Void = mailboxViewModel.loadSendAs()
        async let categoryLoad: Void = mailboxViewModel.loadCategoryUnreadCounts()
        async let calendarLoad: Void = calendar.startCalendarSync(for: id, db: sync.mailDatabase)
        async let agendaLoad: Void = calendar.loadMiniAgendaEvents(db: sync.mailDatabase, accountID: id)
        let syncerForPhotos = sync.backgroundSyncer
        async let photosLoad: Void = {
            if let syncer = syncerForPhotos {
                await PeopleAPIService.shared.loadContactPhotos(accountID: id, syncer: syncer)
            }
        }()
        _ = await (folderLoad, labelsLoad, sendAsLoad, categoryLoad, calendarLoad, agendaLoad, photosLoad)
        guard !Task.isCancelled, navigation.selectedAccountID == id else { return }
        await indexer.resumePending()
        await indexer.scanForAttachments()
    }

    /// Resets selection state and search trigger, then cancels the current lifecycle task.
    /// Called at the start of folder, label, category, and account change handlers.
    private func resetSelectionAndCancelLifecycle() {
        selection.selectedEmail = nil
        selection.selectedEmailIDs = []
        navigation.searchResetTrigger += 1
        sync.cancelLifecycleTasks()
    }

    func handleFolderChange(_ folder: Folder) {
        if sync.accountSwitchTask != nil {
            sync.setPendingFolderChange(folder)
            return
        }
        sync.setPendingFolderChange(nil)
        if let pending = compose.consumePendingDraftSelection() {
            selection.selectedEmail = pending
        } else {
            selection.selectedEmail = nil
        }
        selection.selectedEmailIDs = []
        navigation.searchResetTrigger += 1
        if folder != .labels { navigation.selectedLabel = nil }
        sync.cancelLifecycleTasks()
        if folder == .subscriptions {
            SubscriptionsStore.shared.analyze(mailboxViewModel.emails)
        } else if folder == .snoozed {
            sync.refreshSnoozedCache(fromAddress: navigation.fromAddress)
        } else if folder == .scheduled {
            sync.refreshScheduledCache(fromAddress: navigation.fromAddress)
        } else if folder == .attachments {
            sync.startLifecycle { [weak self] in
                guard let self else { return }
                await attachmentStore.refreshIfNeeded()
                if let indexer = sync.attachmentIndexer {
                    await indexer.scanForAttachments()
                }
            }
        } else if folder == .drafts {
            sync.startLifecycle { [weak self] in
                guard let self else { return }
                await mailStore.syncGmailDrafts(accountID: navigation.accountID)
                self.updateDisplayedEmails()
            }
        } else {
            sync.startLifecycle { [weak self] in
                await self?.loadCurrentFolder()
            }
        }
        updateDisplayedEmails()
    }

    func handleLabelChange() {
        guard navigation.selectedFolder == .labels, navigation.selectedLabel != nil else { return }
        resetSelectionAndCancelLifecycle()
        sync.startLifecycle { [weak self] in
            await self?.loadCurrentFolder()
        }
        updateDisplayedEmails()
    }

    func handleCategoryChange(_ category: InboxCategory?) {
        resetSelectionAndCancelLifecycle()
        sync.startLifecycle { [weak self] in
            await self?.loadCurrentFolder()
        }
        updateDisplayedEmails()
    }

    func handleAccountChange(_ newID: String?) {
        guard let id = newID else { return }
        guard mailboxViewModel.accountID != id else { return }
        let generation = sync.incrementAccountSwitchGeneration()
        UndoActionManager.shared.confirmAll()
        let oldID = mailboxViewModel.accountID
        if !oldID.isEmpty { compose.saveSignatures(for: oldID) }
        mailboxViewModel.accountID = id
        AccountStore.shared.selectedAccountID = id
        compose.loadSignatures(for: id)
        resetSelectionAndCancelLifecycle()
        navigation.selectedInboxCategory = .all
        navigation.selectedLabel = nil
        withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.folderSwitch) {
            navigation.selectedFolder = .inbox
        }
        navigationTask?.cancel()
        ThumbnailCache.shared.clearAll()
        EmailContentCache.shared.clear()
        EmailContentPrefetcher.shared.cancel()
        applyAccountID(id)
        let oldEngine = sync.syncEngine
        let oldCalendarEngine = calendar.calendarSyncEngine
        sync.clearSyncEngines()
        calendar.clearState()
        calendar.viewMode = .mail
        sync.startAccountSwitch { [weak self] in
            guard let self else { return }
            await SnoozeStore.shared.load(accountID: id)
            await ScheduledSendStore.shared.load(accountID: id)
            await OfflineActionQueue.shared.load(accountID: id)
            await UnsubscribeService.shared.load(accountID: id)
            defer {
                if self.sync.currentAccountSwitchGeneration == generation {
                    self.sync.clearAccountSwitchTask()
                    if let folder = self.sync.pendingFolderChange {
                        self.sync.setPendingFolderChange(nil)
                        self.navigation.selectedFolder = folder
                        self.handleFolderChange(folder)
                    }
                }
            }
            await oldEngine?.stop()
            await oldCalendarEngine?.stop()
            await self.attachmentStore.refresh()
            guard !Task.isCancelled, self.sync.currentAccountSwitchGeneration == generation else { return }
            self.syncProgressManager.reset()
            await self.mailboxViewModel.switchAccount(id)
            guard !Task.isCancelled, self.sync.currentAccountSwitchGeneration == generation else { return }
            await self.setupAccount(id)
            self.sync.loadContacts(accountID: id)
            self.updateDisplayedEmails()
        }
    }

    func handleAccountsChange(old: [GmailAccount], new accounts: [GmailAccount]) {
        if navigation.selectedAccountID == nil, let first = accounts.first {
            navigation.selectedAccountID = first.id
        }
        let previousIDs = Set(old.map(\.id))
        let currentIDs = Set(accounts.map(\.id))
        let removedIDs = previousIDs.subtracting(currentIDs)
        let addedIDs = currentIDs.subtracting(previousIDs)

        for addedID in addedIDs {
            Task {
                await SnoozeStore.shared.load(accountID: addedID)
                await ScheduledSendStore.shared.load(accountID: addedID)
                await OfflineActionQueue.shared.load(accountID: addedID)
                await UnsubscribeService.shared.load(accountID: addedID)
            }
            Task { await sync.watchService.registerWatch(accountID: addedID) }
        }

        for removedID in removedIDs {
            GmailAPIClient.shared.clearCachedToken(for: removedID)
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
            UserDefaults.standard.removeObject(forKey: Self.replyDraftsKey(for: removedID))
            UserDefaults.standard.removeObject(forKey: Self.migrationKey(for: removedID))
            Task {
                await sync.watchService.stopWatch(accountID: removedID)
                // If removed account was the Pub/Sub token account, switch to next available
                if await sync.pubSubService.tokenAccountID == removedID {
                    if let next = accounts.first {
                        await sync.pubSubService.setTokenAccountID(next.id)
                    }
                }
            }
        }
        if accounts.isEmpty {
            Task {
                await sync.pubSubService.stop()
                await sync.watchService.stopAll()
            }
        }
        if removedIDs == previousIDs, !removedIDs.isEmpty {
            Task { await SpotlightIndexer.shared.deleteAllItems() }
        }
        if !removedIDs.isEmpty {
            SnoozeMonitor.shared.clearAllFailureCounts()
        }

        if let id = navigation.selectedAccountID, removedIDs.contains(id) {
            let engineToStop = sync.syncEngine
            let calendarEngineToStop = calendar.calendarSyncEngine
            sync.clearSyncEngines()
            calendar.clearState()
            calendar.viewMode = .mail
            EmailContentCache.shared.clear()
            EmailContentPrefetcher.shared.cancel()
            ThumbnailCache.shared.clearAll()
            sync.startLifecycle { [weak self] in
                await engineToStop?.stop()
                await calendarEngineToStop?.stop()
                self?.sync.setMailDatabase(nil)
                self?.sync.setBackgroundSyncer(nil)
            }
            SummaryService.shared.accountID = ""
            navigation.selectedAccountID = accounts.first?.id
        }

        let idsToDelete = removedIDs
        let engineTask = sync.lifecycleTask
        sync.setCleanupTask(Task {
            await engineTask?.value
            for removedID in idsToDelete {
                await FullSyncEngine.stopActive(for: removedID)
            }
            for removedID in idsToDelete {
                MailDatabase.deleteDatabase(accountID: removedID)
                await AttachmentDatabase.shared.deleteByAccountID(removedID)
            }
        })
    }

    // MARK: - Service Routing

    func handleQuickReply(messageId: String, text: String, accountID: String) async {
        do {
            try await sendQuickReply(messageId: messageId, text: text, accountID: accountID)
            ToastManager.shared.show(message: "Reply sent")
        } catch {
            ToastManager.shared.show(message: "Failed to send reply", type: .error)
        }
    }

    @concurrent
    private func sendQuickReply(messageId: String, text: String, accountID: String) async throws {
        let message = try await GmailMessageService.shared.getMessage(
            id: messageId, accountID: accountID, format: "metadata"
        )
        let replySubject = message.subject.withReplyPrefix
        let references = GmailSendService.buildReferencesChain(
            parentReferences: message.header(named: "References"),
            parentMessageID: message.messageID
        )
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
    }

    @concurrent
    func downloadAttachment(messageID: String, attachmentID: String, accountID: String) async throws -> Data {
        try await GmailMessageService.shared.getAttachment(
            messageID: messageID, attachmentID: attachmentID, accountID: accountID
        )
    }

    // MARK: - Preview Panel Actions

    func previewToggleStar(messageID: String, isCurrentlyStarred: Bool, accountID: String) {
        guard let email = mailboxViewModel.emails.first(where: { $0.gmailMessageID == messageID }) else { return }
        Task { await actionCoordinator.toggleStarEmail(email) }
    }

    func previewMarkUnread(messageID: String, accountID: String) {
        guard let email = mailboxViewModel.emails.first(where: { $0.gmailMessageID == messageID }) else { return }
        Task { await actionCoordinator.markUnreadEmail(email) }
    }
}
