import Foundation
private import os

@Observable
@MainActor
final class SyncCoordinator {

    nonisolated private static let logger = Logger(category: "SyncCoordinator")

    // MARK: - State

    private(set) var mailDatabase: MailDatabase?
    private(set) var backgroundSyncer: BackgroundSyncer?
    @ObservationIgnored private(set) var syncEngine: FullSyncEngine?
    var attachmentIndexer: AttachmentIndexer?
    @ObservationIgnored let contactsStore = ContactsStore()

    var undoDuration: Int = { let v = UserDefaults.standard.integer(forKey: UserDefaultsKey.undoDuration); return v != 0 ? v : 5 }() {
        didSet { UserDefaults.standard.set(undoDuration, forKey: UserDefaultsKey.undoDuration) }
    }

    // MARK: - Private State

    @ObservationIgnored var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var accountSwitchGeneration = 0
    @ObservationIgnored var accountSwitchTask: Task<Void, Never>?
    private var cachedSnoozedEmails: [Email] = []
    private var cachedScheduledEmails: [Email] = []
    @ObservationIgnored var pendingFolderChange: Folder?

    // MARK: - Callbacks

    /// Called after cache refresh so AppCoordinator can trigger selection.updateDisplayedEmails().
    @ObservationIgnored var onCacheRefreshed: (() -> Void)?

    // MARK: - Database Lifecycle

    @concurrent
    private func openDatabase(for accountID: String) async throws -> MailDatabase {
        let database = try await MailDatabase.shared(for: accountID)
        guard try database.integrityCheck() else {
            MailDatabase.deleteDatabase(accountID: accountID)
            return try await MailDatabase.shared(for: accountID)
        }
        return database
    }

    func setupDatabase(for accountID: String, selectedAccountID: String?, syncProgressManager: SyncProgressManager) async {
        do {
            let db = try await openDatabase(for: accountID)
            guard selectedAccountID == accountID else { return }
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

    // MARK: - Contacts

    func loadContacts(accountID: String) {
        guard !accountID.isEmpty else { return }
        guard let db = mailDatabase else { return }
        contactsStore.load(accountID: accountID, database: db)
    }

    // MARK: - Snoozed / Scheduled Caches

    func refreshSnoozedCache(fromAddress: String) {
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
        onCacheRefreshed?()
    }

    func refreshSnoozedCacheIfNeeded(folder: Folder, fromAddress: String) {
        guard folder == .snoozed else { return }
        refreshSnoozedCache(fromAddress: fromAddress)
    }

    func refreshScheduledCache(fromAddress: String) {
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
        onCacheRefreshed?()
    }

    func refreshScheduledCacheIfNeeded(folder: Folder, fromAddress: String) {
        guard folder == .scheduled else { return }
        refreshScheduledCache(fromAddress: fromAddress)
    }

    /// Current cached snoozed emails (read-only access for updateDisplayedEmails).
    var snoozedEmails: [Email] { cachedSnoozedEmails }

    /// Current cached scheduled emails (read-only access for updateDisplayedEmails).
    var scheduledEmails: [Email] { cachedScheduledEmails }

    // MARK: - Account Switch Support

    var currentAccountSwitchGeneration: Int { accountSwitchGeneration }

    func incrementAccountSwitchGeneration() -> Int {
        accountSwitchGeneration += 1
        return accountSwitchGeneration
    }

    // MARK: - Cleanup

    func cancelLifecycleTasks() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
    }

    func cancelAllTasks() {
        lifecycleTask?.cancel()
        contactsStore.cancelLoad()
        cleanupTask?.cancel()
        accountSwitchTask?.cancel()
    }

    func clearSyncEngines() {
        syncEngine = nil
    }

    func setSyncEngine(_ engine: FullSyncEngine?) {
        syncEngine = engine
    }

    func setMailDatabase(_ db: MailDatabase?) {
        mailDatabase = db
    }

    func setBackgroundSyncer(_ syncer: BackgroundSyncer?) {
        backgroundSyncer = syncer
    }

    func setCleanupTask(_ task: Task<Void, Never>) {
        cleanupTask = task
    }
}
