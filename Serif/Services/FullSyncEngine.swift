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
    private var progressManager: SyncProgressManager?

    // MARK: - Tasks

    private var syncTask: Task<Void, Never>?
    private var bodyPrefetchTask: Task<Void, Never>?
    private var incrementalTask: Task<Void, Never>?
    private var triggeredSyncTask: Task<Void, Never>?
    private var contactTask: Task<Void, Never>?
    private var labelRefreshTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

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
        triggeredSyncTask?.cancel()
        contactTask?.cancel()
        labelRefreshTask?.cancel()
        restartTask?.cancel()
        syncTask = nil
        bodyPrefetchTask = nil
        incrementalTask = nil
        triggeredSyncTask = nil
        contactTask = nil
        labelRefreshTask = nil
        restartTask = nil
        state = .idle
    }

    /// Request an immediate incremental sync (e.g., user pulled to refresh).
    func triggerIncrementalSync() {
        guard state == .monitoring else { return }
        triggeredSyncTask?.cancel()
        triggeredSyncTask = Task { await syncIncremental() }
    }

    // MARK: - Main Lifecycle

    private func runSyncLifecycle() async {
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
            // Capture a reliable historyId from the profile before listing messages.
            // Using messages.list would yield a stale historyId if new mail arrives
            // during the (potentially long) initial sync.
            await quota.waitForBudget(1) // users.getProfile = 1 unit
            let profile = try await api.getProfile(accountID: accountID)
            let profileHistoryId = profile.historyId

            // Persist the profile historyId immediately so incremental sync can
            // resume from this point even if initial sync is interrupted.
            let capturedProfileHistoryId = profileHistoryId
            await writeSyncState { state in
                state.lastHistoryId = capturedProfileHistoryId
            }

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

                // Write to DB
                let labelIds = Array(Set(messages.flatMap { $0.labelIds ?? [] }))
                try await syncer.upsertMessages(messages, ensureLabels: labelIds)

                syncedCount += messages.count

                // Persist resume state
                let capturedSyncedCount = syncedCount
                let capturedTotalEstimate = totalEstimate
                let nextPageToken = response.nextPageToken
                await writeSyncState { state in
                    state.initialSyncPageToken = nextPageToken
                    state.syncedMessageCount = capturedSyncedCount
                    state.totalMessagesEstimate = capturedTotalEstimate
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
            var allAdded: Set<String> = []
            var addedMessageLabels: [String: [String]] = [:]
            var allDeleted: Set<String> = []
            var labelChanges: Set<String> = []
            var latestHistoryId = startHistoryId
            var pageToken: String? = nil

            repeat {
                await quota.waitForBudget(2) // history.list = 2 units per page
                guard !Task.isCancelled else { return }

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
                        allAdded.insert(added.message.id)
                        // Capture labelIds from history so we can skip re-fetch for existing messages
                        if let labels = added.message.labelIds {
                            addedMessageLabels[added.message.id] = labels
                        }
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

            // Save historyId immediately after pagination completes.
            // On transient metadata fetch failures below, the next sync won't
            // re-process already-seen history records.
            let capturedHistoryId = latestHistoryId
            await writeSyncState { state in
                state.lastHistoryId = capturedHistoryId
            }

            // Separate truly new messages (not in local DB) from existing ones.
            // For existing messages that appear in messagesAdded (e.g. label changes),
            // use the labelIds from the history record directly instead of re-fetching.
            let candidateIDs = Array(allAdded.subtracting(allDeleted))
            var existingIDs = Set<String>()
            if !candidateIDs.isEmpty {
                existingIDs = try await db.dbPool.read { db in
                    let placeholders = candidateIDs.map { _ in "?" }.joined(separator: ",")
                    return try Set(String.fetchAll(db, sql:
                        "SELECT gmail_id FROM messages WHERE gmail_id IN (\(placeholders))",
                        arguments: StatementArguments(candidateIDs)
                    ))
                }
            }
            let trulyNewIDs = candidateIDs.filter { !existingIDs.contains($0) }

            // Existing messages from messagesAdded: apply label updates from history data
            let historyLabelUpdates: [(gmailId: String, labelIds: [String])] = candidateIDs
                .filter { existingIDs.contains($0) }
                .compactMap { id in
                    guard let labels = addedMessageLabels[id] else { return nil }
                    return (gmailId: id, labelIds: labels)
                }

            var newMessages: [GmailMessage] = []
            if !trulyNewIDs.isEmpty {
                await quota.waitForBudget(trulyNewIDs.count * 5)
                newMessages = try await api.getMessages(
                    ids: trulyNewIDs, accountID: accountID, format: "metadata"
                )
            }

            // Fetch updated label info for changed messages.
            // "minimal" format is sufficient — we only need id and labelIds.
            let toRefetch = labelChanges.subtracting(allDeleted).subtracting(Set(candidateIDs))
            var labelUpdates: [(gmailId: String, labelIds: [String])] = historyLabelUpdates
            if !toRefetch.isEmpty {
                await quota.waitForBudget(toRefetch.count * 5)
                let refreshed = try await api.getMessages(
                    ids: Array(toRefetch), accountID: accountID, format: "minimal"
                )
                labelUpdates += refreshed.map { (gmailId: $0.id, labelIds: $0.labelIds ?? []) }
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

            // Record last sync timestamp (historyId already saved above after pagination)
            await writeSyncState { state in
                state.lastSyncAt = Date().timeIntervalSince1970
            }

        } catch {
            if case .httpError(404, _) = error as? GmailAPIError {
                // historyId expired — restart full sync.
                // Cancel sibling tasks directly instead of going through stop(),
                // which would cancel restartTask itself (the task we're about to create).
                Self.logger.warning("History ID expired, restarting full sync")
                await writeSyncState { state in
                    state.initialSyncComplete = false
                    state.initialSyncPageToken = nil
                    state.lastHistoryId = nil
                    state.syncedMessageCount = 0
                }
                state = .idle
                syncTask?.cancel()
                syncTask = nil
                bodyPrefetchTask?.cancel()
                bodyPrefetchTask = nil
                incrementalTask?.cancel()
                incrementalTask = nil
                triggeredSyncTask?.cancel()
                triggeredSyncTask = nil
                contactTask?.cancel()
                contactTask = nil
                labelRefreshTask?.cancel()
                labelRefreshTask = nil
                restartTask = Task { [weak self] in
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
                } else if remaining < 0 {
                    // Error — back off 30s to avoid tight retry loop
                    try? await Task.sleep(for: .seconds(30))
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
    func updatePollingInterval(appIsActive: Bool, windowIsKey: Bool) {
        if !appIsActive || !windowIsKey {
            _pollingOverride = 60
        } else {
            _pollingOverride = nil // use default 30s
        }
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
            let currentEtag = await readSyncState()?.labelsEtag
            await quota.waitForBudget(1)
            let result = try await GmailLabelService.shared.listLabels(
                etag: currentEtag, accountID: accountID
            )
            guard let (labels, responseEtag) = result else {
                // 304 Not Modified — labels unchanged
                return
            }
            try await syncer.upsertLabels(labels)
            if let responseEtag {
                await writeSyncState { $0.labelsEtag = responseEtag }
            }
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
                await PeopleAPIService.shared.refreshContacts(accountID: accountID, syncer: syncer)
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

    private func reportProgress(_ action: @Sendable @MainActor (SyncProgressManager) -> Void) async {
        guard let manager = progressManager else { return }
        await MainActor.run { action(manager) }
    }
}
