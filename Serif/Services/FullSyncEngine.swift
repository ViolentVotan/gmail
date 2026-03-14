import Foundation
import GRDB
private import os

/// Orchestrates complete offline sync for a single Gmail account.
/// Manages: initial full sync, incremental History API polling,
/// body pre-fetch, label refresh, and contact refresh.
actor FullSyncEngine {
    // MARK: - State

    enum State: Equatable, Sendable {
        case idle
        case initialSync
        case monitoring
        case error(String)
    }

    private(set) var state: State = .idle

    // MARK: - Dependencies

    private let accountID: String
    private let db: MailDatabase
    private let syncer: BackgroundSyncer
    private let api: MessageFetching
    private let quota: QuotaTracker
    private nonisolated(unsafe) var progressManager: SyncProgressManager?

    // MARK: - Tasks

    private var syncTask: Task<Void, Never>?
    private var bodyPrefetchTask: Task<Void, Never>?
    private var incrementalTask: Task<Void, Never>?
    private var contactTask: Task<Void, Never>?
    private var labelRefreshTask: Task<Void, Never>?

    // MARK: - Config

    /// Adaptive polling: 15s (active inbox), 30s (composing/settings), 60s (background)
    private var pollingInterval: TimeInterval {
        _pollingOverride ?? 30
    }
    private var _pollingOverride: TimeInterval?

    nonisolated private static let logger = Logger(
        subsystem: "com.vikingz.serif", category: "SyncEngine"
    )

    // MARK: - Init

    @MainActor
    init(
        accountID: String,
        db: MailDatabase,
        syncer: BackgroundSyncer,
        api: MessageFetching = GmailMessageService.shared,
        quota: QuotaTracker = QuotaTracker()
    ) {
        self.accountID = accountID
        self.db = db
        self.syncer = syncer
        self.api = api
        self.quota = quota
    }

    @MainActor
    func setProgressManager(_ manager: SyncProgressManager) {
        progressManager = manager
    }

    // MARK: - Lifecycle

    func start() {
        guard state == .idle else { return }
        syncTask = Task { await runSyncLifecycle() }
    }

    func stop() {
        syncTask?.cancel()
        bodyPrefetchTask?.cancel()
        incrementalTask?.cancel()
        contactTask?.cancel()
        labelRefreshTask?.cancel()
        syncTask = nil
        bodyPrefetchTask = nil
        incrementalTask = nil
        contactTask = nil
        labelRefreshTask = nil
        state = .idle
    }

    /// Request an immediate incremental sync (e.g., user pulled to refresh).
    func triggerIncrementalSync() {
        guard state == .monitoring else { return }
        Task { await syncIncremental() }
    }

    // MARK: - Main Lifecycle

    private func runSyncLifecycle() async {
        // One-time migration: copy historyId from AccountStore to DB
        await migrateHistoryIdIfNeeded()

        // Read sync state from DB
        let syncState = await readSyncState()

        if syncState?.initialSyncComplete == true {
            // Resume monitoring mode
            state = .monitoring
            await reportProgress { $0.syncStarted() }

            // Immediate incremental sync to catch up
            await syncIncremental()
            await reportProgress { $0.syncCompleted() }

            // Start background loops
            startIncrementalLoop()
            startBodyPrefetchLoop()
            startContactRefreshLoop()
            startLabelRefreshLoop()
        } else {
            // Initial or resumed full sync
            state = .initialSync
            let resumeToken = syncState?.initialSyncPageToken

            let success = await performInitialSync(resumeFrom: resumeToken)
            guard !Task.isCancelled else { return }

            if success {
                state = .monitoring
                startIncrementalLoop()
                startBodyPrefetchLoop()
                startContactRefreshLoop()
                startLabelRefreshLoop()
            } else {
                state = .error("Initial sync failed")
            }
        }
    }

    // MARK: - Initial Sync

    private func performInitialSync(resumeFrom pageToken: String?) async -> Bool {
        Self.logger.info("Starting initial sync for \(self.accountID)")
        var currentPageToken = pageToken
        var firstHistoryId: String?
        var totalEstimate: Int?
        var syncedCount = 0

        // If resuming, load previous progress
        if let state = await readSyncState() {
            syncedCount = state.syncedMessageCount
            totalEstimate = state.totalMessagesEstimate
        }

        // Sync labels first (1 quota unit)
        await syncLabels()

        do {
            repeat {
                guard !Task.isCancelled else { return false }

                // Pace: messages.list = 5 units
                await quota.waitForBudget(5)
                guard !Task.isCancelled else { return false }

                let response = try await api.listMessages(
                    accountID: accountID,
                    labelIDs: [],
                    query: nil,
                    pageToken: currentPageToken,
                    maxResults: 500
                )

                let refs = response.messages ?? []
                if totalEstimate == nil, let estimate = response.resultSizeEstimate {
                    totalEstimate = estimate
                }

                guard !refs.isEmpty else { break }

                // Batch-fetch metadata (50 per batch x 5 units = 250 units/batch)
                let ids = refs.map(\.id)
                await quota.waitForBudget(ids.count * 5)
                guard !Task.isCancelled else { return false }

                let messages = try await api.getMessages(
                    ids: ids, accountID: accountID, format: "metadata"
                )

                // Store historyId from the first (newest) batch only
                if firstHistoryId == nil, let hid = messages.compactMap(\.historyId).first {
                    firstHistoryId = hid
                }

                // Write to DB
                let labelIds = Array(Set(messages.flatMap { $0.labelIds ?? [] }))
                try await syncer.upsertMessages(messages, ensureLabels: labelIds)

                syncedCount += messages.count

                // Persist resume state
                let capturedSyncedCount = syncedCount
                let capturedTotalEstimate = totalEstimate
                let capturedHistoryId = firstHistoryId
                let nextPageToken = response.nextPageToken
                await writeSyncState { state in
                    state.initialSyncPageToken = nextPageToken
                    state.syncedMessageCount = capturedSyncedCount
                    state.totalMessagesEstimate = capturedTotalEstimate
                    if let hid = capturedHistoryId {
                        state.lastHistoryId = hid
                    }
                }

                // Report progress
                await reportProgress { manager in
                    manager.initialSyncProgress(
                        synced: syncedCount,
                        estimated: totalEstimate ?? syncedCount
                    )
                }

                currentPageToken = response.nextPageToken
            } while currentPageToken != nil

            // Mark initial sync complete
            await writeSyncState { state in
                state.initialSyncComplete = true
                state.initialSyncPageToken = nil
                state.lastSyncAt = Date().timeIntervalSince1970
            }

            await reportProgress { $0.syncCompleted() }
            Self.logger.info("Initial sync complete: \(syncedCount) messages")
            return true

        } catch is CancellationError {
            return false
        } catch {
            Self.logger.error("Initial sync failed: \(error.localizedDescription)")
            await reportProgress { $0.syncFailed(error.localizedDescription) }
            return false
        }
    }

    // MARK: - Incremental Sync

    private func startIncrementalLoop() {
        incrementalTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollingInterval))
                guard !Task.isCancelled else { return }
                // Pause when offline
                let isConnected = await MainActor.run { NetworkMonitor.shared.isConnected }
                guard isConnected else { continue }
                await syncIncremental()
            }
        }
    }

    private func syncIncremental() async {
        guard let syncState = await readSyncState(),
              let startHistoryId = syncState.lastHistoryId else { return }

        do {
            await quota.waitForBudget(2) // history.list = 2 units
            guard !Task.isCancelled else { return }

            var allAdded: [String] = []
            var allDeleted: Set<String> = []
            var labelChanges: Set<String> = []
            var latestHistoryId = startHistoryId
            var pageToken: String? = nil

            repeat {
                let response = try await api.listHistory(
                    accountID: accountID,
                    startHistoryId: startHistoryId,
                    labelId: nil,
                    pageToken: pageToken,
                    maxResults: 500
                )

                latestHistoryId = response.historyId
                pageToken = response.nextPageToken

                for record in response.history ?? [] {
                    for added in record.messagesAdded ?? [] {
                        allAdded.append(added.message.id)
                    }
                    for deleted in record.messagesDeleted ?? [] {
                        allDeleted.insert(deleted.message.id)
                    }
                    for labelAdd in record.labelsAdded ?? [] {
                        labelChanges.insert(labelAdd.message.id)
                    }
                    for labelRemove in record.labelsRemoved ?? [] {
                        labelChanges.insert(labelRemove.message.id)
                    }
                }
            } while pageToken != nil

            // Fetch metadata for new messages
            let newIDs = allAdded.filter { !allDeleted.contains($0) }
            var newMessages: [GmailMessage] = []
            if !newIDs.isEmpty {
                await quota.waitForBudget(newIDs.count * 5)
                newMessages = try await api.getMessages(
                    ids: newIDs, accountID: accountID, format: "metadata"
                )
            }

            // Fetch updated label info for changed messages
            let toRefetch = labelChanges.subtracting(allDeleted).subtracting(Set(newIDs))
            var labelUpdates: [(gmailId: String, labelIds: [String])] = []
            if !toRefetch.isEmpty {
                await quota.waitForBudget(toRefetch.count * 5)
                let refreshed = try await api.getMessages(
                    ids: Array(toRefetch), accountID: accountID, format: "metadata"
                )
                labelUpdates = refreshed.map { (gmailId: $0.id, labelIds: $0.labelIds ?? []) }
            }

            // Apply delta to DB
            try await syncer.applyDelta(
                newMessages: newMessages,
                deletedIds: Array(allDeleted),
                labelUpdates: labelUpdates
            )

            // Fetch full bodies for new messages immediately
            if !newMessages.isEmpty {
                await quota.waitForBudget(newMessages.count * 5)
                let fullMessages = try await api.getMessages(
                    ids: newMessages.map(\.id), accountID: accountID, format: "full"
                )
                let updates = fullMessages.map { msg in
                    (gmailId: msg.id, html: msg.htmlBody, plain: msg.plainBody)
                }
                try await syncer.updateBodies(updates)
            }

            // Fire local notifications for new inbox messages
            await fireNotifications(for: newMessages)

            // Update history ID
            let capturedHistoryId = latestHistoryId
            await writeSyncState { state in
                state.lastHistoryId = capturedHistoryId
                state.lastSyncAt = Date().timeIntervalSince1970
            }

        } catch {
            if case .httpError(404, _) = error as? GmailAPIError {
                // historyId expired — restart full sync
                Self.logger.warning("History ID expired, restarting full sync")
                await writeSyncState { state in
                    state.initialSyncComplete = false
                    state.initialSyncPageToken = nil
                    state.lastHistoryId = nil
                    state.syncedMessageCount = 0
                }
                Task { [weak self] in
                    await self?.stop()
                    await self?.start()
                }
                return
            } else {
                Self.logger.error("Incremental sync error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Body Pre-fetch

    private func startBodyPrefetchLoop() {
        bodyPrefetchTask = Task {
            while !Task.isCancelled {
                let remaining = await bodyPrefetchTick()
                guard !Task.isCancelled else { return }
                if remaining == 0 {
                    // All bodies fetched — sleep 60s then check again
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    /// Fetches one batch of bodies. Returns count of remaining messages without bodies.
    private func bodyPrefetchTick() async -> Int {
        do {
            let toFetch = try await db.dbPool.read { db in
                try MailDatabaseQueries.messagesNeedingBodies(limit: 50, in: db)
            }
            guard !toFetch.isEmpty else {
                return 0
            }

            let ids = toFetch.map(\.gmailId)
            await quota.waitForBudget(ids.count * 5)
            guard !Task.isCancelled else { return 0 }

            let fullMessages = try await api.getMessages(
                ids: ids, accountID: accountID, format: "full"
            )
            let updates = fullMessages.map { msg in
                (gmailId: msg.id, html: msg.htmlBody, plain: msg.plainBody)
            }
            try await syncer.updateBodies(updates)

            let remaining = try await db.dbPool.read { db in
                try MailDatabaseQueries.messagesWithoutBodiesCount(in: db)
            }

            await reportProgress { $0.bodyPrefetchProgress(remaining: remaining) }
            return remaining

        } catch {
            Self.logger.error("Body prefetch error: \(error.localizedDescription)")
            return -1 // Error, will retry
        }
    }

    // MARK: - Adaptive Polling

    /// Update polling interval based on app state.
    @MainActor
    func updatePollingInterval(appIsActive: Bool, windowIsKey: Bool) {
        Task {
            if !appIsActive || !windowIsKey {
                await setPollingOverride(60)
            } else {
                await setPollingOverride(nil) // use default 30s
            }
        }
    }

    private func setPollingOverride(_ interval: TimeInterval?) {
        _pollingOverride = interval
    }

    // MARK: - Label Refresh (every 5 minutes)

    private func startLabelRefreshLoop() {
        labelRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300)) // 5 minutes
                guard !Task.isCancelled else { return }
                await syncLabels()
            }
        }
    }

    // MARK: - Label Sync

    private func syncLabels() async {
        do {
            await quota.waitForBudget(1)
            let labels = try await GmailLabelService.shared.listLabels(accountID: accountID)
            try await syncer.upsertLabels(labels)
        } catch {
            Self.logger.error("Label sync error: \(error.localizedDescription)")
        }
    }

    // MARK: - Contact Refresh

    private func startContactRefreshLoop() {
        contactTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800)) // 30 minutes
                guard !Task.isCancelled else { return }
                await PeopleAPIService.shared.refreshContacts(accountID: accountID)
            }
        }
    }

    // MARK: - Notifications

    @MainActor
    private func fireNotifications(for messages: [GmailMessage]) {
        let inboxMessages = messages
            .filter { $0.labelIds?.contains(GmailSystemLabel.inbox) == true }
            .prefix(5)
        for msg in inboxMessages {
            let fromRaw = msg.from
            let senderName = fromRaw
                .components(separatedBy: "<")
                .first?
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                ?? fromRaw
            NotificationService.shared.notifyNewEmail(
                messageId: msg.id,
                threadId: msg.threadId,
                senderName: senderName.isEmpty ? fromRaw : senderName,
                subject: msg.subject,
                snippet: msg.snippet ?? "",
                accountID: accountID
            )
        }
    }

    // MARK: - DB Helpers

    private func migrateHistoryIdIfNeeded() async {
        // historyId was previously stored on GmailAccount (UserDefaults).
        // It is now stored exclusively in account_sync_state.last_history_id.
        // The GmailAccount.historyId property has been removed; migration is complete.
    }

    private func readSyncState() async -> AccountSyncStateRecord? {
        try? await db.dbPool.read { db in
            try MailDatabaseQueries.syncState(in: db)
        }
    }

    private func writeSyncState(_ update: @Sendable (inout AccountSyncStateRecord) -> Void) async {
        try? await db.dbPool.write { db in
            try MailDatabaseQueries.updateSyncState(update, in: db)
        }
    }

    @MainActor
    private func reportProgress(_ action: @MainActor (SyncProgressManager) -> Void) {
        guard let manager = progressManager else { return }
        action(manager)
    }
}
