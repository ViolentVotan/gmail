import Foundation
internal import GRDB
private import os
import Synchronization

extension Notification.Name {
    /// Posted when the sync engine encounters a fatal auth error (.unauthorized / .tokenRevoked).
    /// `userInfo` contains `["accountID": String]`.
    static let syncSessionExpired = Notification.Name("FullSyncEngine.syncSessionExpired")
}

/// Orchestrates complete offline sync for a single Gmail account.
/// Manages: initial full sync, incremental History API polling,
/// body pre-fetch, label refresh, and contact refresh.
/// Progress events emitted by `FullSyncEngine` to update UI.
/// A Sendable value type — safe to cross actor boundaries.
enum SyncProgressEvent: Sendable {
    case started
    case progress(remaining: Int)
    case initialProgress(synced: Int, estimated: Int)
    case bodyPrefetch(remaining: Int)
    case completed
    case failed(String = "Sync failed")
}

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
    private let onProgress: @Sendable (SyncProgressEvent) async -> Void

    // MARK: - Tasks

    private var syncTask: Task<Void, Never>?
    private var bodyPrefetchTask: Task<Void, Never>?
    private var incrementalTask: Task<Void, Never>?
    private var triggeredSyncTask: Task<Void, Never>?
    private var contactTask: Task<Void, Never>?
    private var labelRefreshTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

    /// Reentrancy guard: prevents overlapping `syncIncremental()` runs.
    /// The polling loop's `incrementalTask` and user-triggered `triggeredSyncTask`
    /// can both call `syncIncremental()` — actor reentrancy allows the second call
    /// to start while the first is suspended at an `await`. This flag is set/cleared
    /// synchronously (no `await` between check and set), so it's actor-safe.
    // Shared reentrancy guard pattern — also in CalendarSyncEngine
    private var isSyncingIncrementally = false

    /// Reentrancy guard: prevents concurrent `syncFolderIfEmpty` calls for the same folder.
    /// Rapid navigation (e.g. Spam↔Trash) can trigger multiple calls before the first finishes.
    private var inProgressFolders = Set<String>()

    /// Consecutive incremental sync failures — drives adaptive backoff.
    private var consecutiveFailures = 0

    /// Set by `performInitialSync` when token is permanently revoked.
    /// Checked by the retry loop to avoid retrying auth failures.
    private var isTokenRevoked = false

    /// When true, Pub/Sub is delivering notifications — use 300s backup polling.
    /// When false, use normal polling (60s default or _pollingOverride).
    private(set) var pubSubActive: Bool = false

    // MARK: - Config

    /// Precedence: pubSubActive (300s) > _pollingOverride > default (60s).
    /// When Pub/Sub is active, backup polling is always 300s regardless of app focus state.
    private var pollingInterval: TimeInterval {
        pubSubActive ? PubSubConfig.backupPollingInterval : (_pollingOverride ?? 60)
    }
    private var _pollingOverride: TimeInterval?

    nonisolated private static let logger = Logger(
        subsystem: "com.vikingz.vik", category: "SyncEngine"
    )

    // MARK: - Active Engine Registry

    /// Tracks the active engine per account so `setupAccount` can stop a zombie
    /// engine from a previous window before creating a replacement.
    private static let activeEngines = Mutex<[String: FullSyncEngine]>([:])

    /// Stops and removes any active engine for the given account.
    /// Call before creating a replacement engine to prevent zombie engines
    /// when the window is closed and reopened without quitting the app.
    static func stopActive(for accountID: String) async {
        let old = activeEngines.withLock { $0.removeValue(forKey: accountID) }
        await old?.stop()
    }

    /// Stops all active engines and clears the registry.
    /// Call from app lifecycle (e.g. `applicationWillTerminate`) to ensure
    /// in-flight sync tasks complete before process exit.
    static func cleanupAll() async {
        let engines = activeEngines.withLock { engines in
            let copy = engines
            engines.removeAll()
            return copy
        }
        for (_, engine) in engines {
            await engine.stop()
        }
    }

    // MARK: - Init

    init(
        accountID: String,
        db: MailDatabase,
        syncer: BackgroundSyncer,
        api: MessageFetching,
        quota: QuotaTracker = .shared,
        onProgress: @escaping @Sendable (SyncProgressEvent) async -> Void = { _ in }
    ) {
        self.accountID = accountID
        self.db = db
        self.syncer = syncer
        self.api = api
        self.quota = quota
        self.onProgress = onProgress
    }

    isolated deinit {
        Self.activeEngines.withLock { $0.removeValue(forKey: accountID) }
    }

    // MARK: - Lifecycle

    func start() {
        guard syncTask == nil else {
            Self.logger.warning("start() skipped — syncTask already exists, state=\(String(describing: self.state))")
            return
        }
        Self.logger.info("start() — launching sync lifecycle")
        state = .idle
        isTokenRevoked = false
        syncTask = Task { await runSyncLifecycle() }
        Self.activeEngines.withLock { $0[accountID] = self }
    }

    func stop() async {
        let id = accountID
        Self.activeEngines.withLock { (engines: inout [String: FullSyncEngine]) in
            if engines[id] === self { engines[id] = nil }
        }

        // Cancel all tasks first.
        syncTask?.cancel()
        bodyPrefetchTask?.cancel()
        incrementalTask?.cancel()
        triggeredSyncTask?.cancel()
        contactTask?.cancel()
        labelRefreshTask?.cancel()
        restartTask?.cancel()

        // Snapshot task references so we can await them concurrently without
        // re-entering the actor for each individual await.
        let snap = (
            sync: syncTask,
            body: bodyPrefetchTask,
            incremental: incrementalTask,
            triggered: triggeredSyncTask,
            contact: contactTask,
            labelRefresh: labelRefreshTask,
            restart: restartTask
        )

        // Await the 6 independent tasks concurrently, then restartTask last
        // (it may call start(), spawning a new syncTask — handled below).
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await snap.sync?.value }
            group.addTask { await snap.body?.value }
            group.addTask { await snap.incremental?.value }
            group.addTask { await snap.triggered?.value }
            group.addTask { await snap.contact?.value }
            group.addTask { await snap.labelRefresh?.value }
        }
        await snap.restart?.value

        // restartTask may have called start(), creating a new syncTask.
        syncTask?.cancel()
        await syncTask?.value

        syncTask = nil
        bodyPrefetchTask = nil
        incrementalTask = nil
        triggeredSyncTask = nil
        contactTask = nil
        labelRefreshTask = nil
        restartTask = nil
        state = .idle
    }

    /// Cancel and nil all task references without awaiting completion.
    /// Used for tear-down from within a running task (where `stop()` would
    /// self-deadlock because it awaits the calling task's `.value`).
    private func cancelAllTasks() {
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
    }

    /// Cancel and nil all task references except `restartTask`.
    /// Used in the 410/restart path so that `restartTask` is already assigned
    /// before other tasks are cancelled — prevents a race where `stop()` sees
    /// `restartTask == nil` and doesn't wait, allowing a zombie engine.
    private func cancelNonRestartTasks() {
        syncTask?.cancel()
        bodyPrefetchTask?.cancel()
        incrementalTask?.cancel()
        triggeredSyncTask?.cancel()
        contactTask?.cancel()
        labelRefreshTask?.cancel()
        syncTask = nil
        bodyPrefetchTask = nil
        incrementalTask = nil
        triggeredSyncTask = nil
        contactTask = nil
        labelRefreshTask = nil
    }

    /// Request an immediate incremental sync (e.g., user tapped sync bubble).
    /// Also accepts `.error` state to restart the full sync lifecycle after failure.
    func triggerIncrementalSync() {
        Self.logger.info("triggerIncrementalSync() called — state=\(String(describing: self.state))")
        if case .error = state {
            // Restart full lifecycle. Cancel any orphaned task before clearing
            // the ref — rapid double-invocation can leave a running task that
            // would otherwise be unreachable and uncancel-able.
            syncTask?.cancel()
            syncTask = nil
            start()
            return
        }
        guard state == .monitoring else {
            Self.logger.warning("triggerIncrementalSync() skipped — state is \(String(describing: self.state)), not .monitoring")
            return
        }
        triggeredSyncTask?.cancel()
        triggeredSyncTask = Task {
            await reportProgress(.started)
            let succeeded = await syncIncremental()
            if !Task.isCancelled {
                if succeeded {
                    await reportProgress(.completed)
                } else {
                    await reportProgress(.failed())
                }
            }
        }
    }

    /// Stops the engine and posts a notification so the UI can auto-trigger re-auth.
    private func handleFatalAuthError() async {
        let id = accountID
        cancelAllTasks()
        Self.activeEngines.withLock { _ = $0.removeValue(forKey: id) }
        state = .error("Session expired — signing in…")
        await reportProgress(.failed("Session expired — signing in…"))
        await MainActor.run {
            NotificationCenter.default.post(
                name: .syncSessionExpired,
                object: nil,
                userInfo: ["accountID": id]
            )
        }
    }

    /// Fetches messages for a specific label if the local DB has none.
    /// Used to lazy-load Spam/Trash on first navigation.
    func syncFolderIfEmpty(labelId: String) async {
        guard state == .monitoring else { return }

        // Reentrancy guard: rapid folder navigation can trigger concurrent calls.
        guard inProgressFolders.insert(labelId).inserted else { return }
        defer { inProgressFolders.remove(labelId) }

        // Check if we already have messages for this label
        let count = (try? await db.dbPool.read { db in
            try MailDatabaseQueries.messageCountForLabel(labelId, in: db)
        }) ?? 0
        guard count == 0 else { return }

        Self.logger.info("Lazy-loading folder \(labelId, privacy: .private)")

        do {
            // List up to 500 message IDs for this label
            var allIDs: [String] = []
            var pageToken: String? = nil
            repeat {
                await quota.waitForBudget(5)
                guard !Task.isCancelled else { return }
                let response = try await api.listMessages(
                    accountID: accountID,
                    labelIDs: [labelId],
                    query: nil,
                    pageToken: pageToken,
                    maxResults: 500
                )
                allIDs.append(contentsOf: response.messages?.map(\.id) ?? [])
                pageToken = response.nextPageToken
            } while pageToken != nil && allIDs.count < 2000

            guard !allIDs.isEmpty, !Task.isCancelled else { return }

            // Fetch metadata in chunks of 50 (matching batchFetch's internal chunk size),
            // waiting for each chunk's quota budget separately. Pre-consuming the full
            // budget upfront (allIDs.count * 5, up to 10K units) would starve other
            // operations by consuming 2/3 of the per-minute budget at once.
            let chunkSize = 50
            for chunkStart in stride(from: 0, to: allIDs.count, by: chunkSize) {
                guard !Task.isCancelled else { return }
                let chunkEnd = min(chunkStart + chunkSize, allIDs.count)
                let chunk = Array(allIDs[chunkStart..<chunkEnd])
                await quota.waitForBudget(chunk.count * 5)
                guard !Task.isCancelled else { return }
                let (messages, _) = try await api.getMessages(
                    ids: chunk, accountID: accountID, format: "metadata"
                )

                let labelIds = Set(messages.flatMap { $0.labelIds ?? [] })
                try await syncer.upsertMessages(messages, ensureLabels: Array(labelIds))
            }
        } catch {
            Self.logger.error("Lazy folder sync error for \(labelId, privacy: .private): \(error.localizedDescription)")
        }
    }

    // MARK: - Main Lifecycle

    private func runSyncLifecycle() async {
        // Read sync state from DB
        let syncState = await readSyncState()
        Self.logger.info("runSyncLifecycle: initialSyncComplete=\(syncState?.initialSyncComplete ?? false), lastHistoryId=\(syncState?.lastHistoryId ?? "nil", privacy: .private)")

        if syncState?.initialSyncComplete == true {
            // Resume monitoring mode
            state = .monitoring
            Self.logger.info("runSyncLifecycle: entering monitoring mode, running immediate incremental sync")
            await reportProgress(.started)

            // Immediate incremental sync to catch up
            let succeeded = await syncIncremental()
            if succeeded {
                await reportProgress(.completed)
            } else {
                await reportProgress(.failed())
            }

            // Start background loops
            startIncrementalLoop()
            startBodyPrefetchLoop()
            startContactRefreshLoop()
            startLabelRefreshLoop()
        } else {
            // Initial or resumed full sync
            state = .initialSync

            // Retry with exponential backoff (1s, 2s, 4s) per Gmail API guidance.
            // initialSyncProgress() is called at the top of each attempt so the
            // bubble always shows the current count — avoiding interim syncFailed
            // calls that would trigger the 2.5s auto-dismiss linger timer.
            var attempt = 0
            let maxRetries = 3
            while !Task.isCancelled {
                let resumeState = await readSyncState()
                let resumeToken = resumeState?.initialSyncPageToken
                // Show initial sync progress immediately (with resumed counts if available)
                let resumedCount = resumeState?.syncedMessageCount ?? 0
                let resumedEstimate = resumeState?.totalMessagesEstimate ?? 0
                await reportProgress(.initialProgress(synced: resumedCount, estimated: resumedEstimate))
                let success = await performInitialSync(resumeFrom: resumeToken)
                guard !Task.isCancelled else { return }

                if success {
                    state = .monitoring
                    // Immediate incremental sync to catch mail arriving during initial sync
                    // (the historyId captured before listing covers this gap)
                    let gapFillOK = await syncIncremental()
                    if !gapFillOK {
                        await reportProgress(.failed("Gap-fill sync failed"))
                    }
                    startIncrementalLoop()
                    startBodyPrefetchLoop()
                    startContactRefreshLoop()
                    startLabelRefreshLoop()
                    return
                }

                // Don't retry auth errors — user must re-authenticate.
                // Remove from registry to prevent leak (stop() won't be called).
                if isTokenRevoked {
                    Self.activeEngines.withLock { _ = $0.removeValue(forKey: accountID) }
                    return
                }

                attempt += 1
                if attempt > maxRetries {
                    state = .error("Initial sync failed")
                    // Clear stale page token so manual retry starts fresh.
                    // Log warning if the DB write fails — stale token may cause
                    // the next retry to resume from an expired position.
                    let cleared = await writeSyncState { $0.initialSyncPageToken = nil }
                    if !cleared {
                        Self.logger.warning("Failed to clear stale page token — next retry may resume from old position")
                    }
                    await reportProgress(.failed("Sync failed — tap to retry"))
                    // Remove from registry to prevent leak — engine is dead but
                    // triggerIncrementalSync() can restart it via start().
                    Self.activeEngines.withLock { _ = $0.removeValue(forKey: accountID) }
                    return
                }

                let delay = pow(2.0, Double(attempt - 1)) // 1s, 2s, 4s
                Self.logger.info("Initial sync retry \(attempt)/\(maxRetries) in \(delay)s")
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    // MARK: - Initial Sync

    private func performInitialSync(resumeFrom pageToken: String?) async -> Bool {
        Self.logger.info("Starting initial sync for \(self.accountID, privacy: .private)")
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
                    query: "-in:spam -in:trash",
                    pageToken: currentPageToken,
                    maxResults: 500
                )

                let refs = response.messages ?? []
                if totalEstimate == nil, let estimate = response.resultSizeEstimate {
                    totalEstimate = estimate
                }

                guard !refs.isEmpty else { break }

                // Batch-fetch metadata: each messages.get = 5 quota units
                let ids = refs.map(\.id)
                await quota.waitForBudget(ids.count * 5)
                guard !Task.isCancelled else { return false }

                let (messages, failedIDs) = try await api.getMessages(
                    ids: ids, accountID: accountID, format: "metadata"
                )
                if !failedIDs.isEmpty {
                    Self.logger.warning("Initial sync: \(failedIDs.count) message(s) failed to fetch, will retry on next sync")
                }

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
                await reportProgress(.initialProgress(
                    synced: syncedCount,
                    estimated: totalEstimate ?? syncedCount
                ))

                currentPageToken = response.nextPageToken
            } while currentPageToken != nil

            // Mark initial sync complete — guard against DB write failure to avoid
            // losing sync state (would cause a redundant full re-sync on next launch)
            let didPersist = await writeSyncState { state in
                state.initialSyncComplete = true
                state.initialSyncPageToken = nil
                state.lastSyncAt = Date().timeIntervalSince1970
            }
            guard didPersist else {
                Self.logger.error("Failed to persist initialSyncComplete — will retry on next launch")
                await reportProgress(.failed("Failed to save sync state"))
                return false
            }

            await reportProgress(.completed)
            Self.logger.info("Initial sync complete: \(syncedCount) messages")
            return true

        } catch is CancellationError {
            return false
        } catch {
            // Token revoked: set non-retryable flag and report error. Cannot call
            // stop() here — we're inside syncTask, and stop() awaits syncTask.value
            // which would deadlock. The retry loop checks isTokenRevoked to bail.
            if case .tokenRevoked = error as? GoogleAPIError {
                Self.logger.error("Token revoked during initial sync for \(self.accountID, privacy: .private)")
                isTokenRevoked = true
                state = .error("Session expired — signing in…")
                await reportProgress(.failed("Session expired — signing in…"))
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .syncSessionExpired,
                        object: nil,
                        userInfo: ["accountID": accountID]
                    )
                }
                return false
            }
            // Retryable error — log but don't call syncFailed (the retry loop in
            // runSyncLifecycle manages progress; calling syncFailed here would
            // trigger the 2.5s auto-dismiss linger timer mid-retry).
            Self.logger.error("Initial sync failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Incremental Sync

    private func startIncrementalLoop() {
        incrementalTask = Task {
            while !Task.isCancelled {
                // Circuit breaker: pause sync after sustained failures
                if consecutiveFailures >= 5 {
                    Self.logger.warning("Circuit breaker: pausing sync for 15 min after \(self.consecutiveFailures) failures")
                    await reportProgress(.failed("Sync paused — will retry in 15 min"))
                    try? await Task.sleep(for: .seconds(900))
                    guard !Task.isCancelled else { return }
                    consecutiveFailures = 0
                    continue
                }

                let backoff = consecutiveFailures > 0
                    ? min(pollingInterval * pow(2.0, Double(consecutiveFailures)), 300)
                    : pollingInterval
                try? await Task.sleep(for: .seconds(backoff))
                guard !Task.isCancelled else { return }
                // Pause when offline
                guard NetworkMonitor.isReachable else { continue }
                let ok = await syncIncremental()
                // Surface persistent failures so the user knows sync is broken
                if !ok && consecutiveFailures >= 3 {
                    await reportProgress(.failed("Sync failing — tap to retry"))
                }
            }
        }
    }

    @discardableResult
    private func syncIncremental() async -> Bool {
        guard !isSyncingIncrementally else {
            Self.logger.info("syncIncremental: skipped — already syncing incrementally")
            return false
        }
        isSyncingIncrementally = true
        defer { isSyncingIncrementally = false }

        guard let syncState = await readSyncState(),
              let startHistoryId = syncState.lastHistoryId else {
            Self.logger.warning("syncIncremental: no sync state or historyId — returning true without syncing")
            return true
        }
        Self.logger.info("syncIncremental: starting with historyId=\(startHistoryId, privacy: .private)")

        do {
            var allAdded: Set<String> = []
            var addedMessageLabels: [String: [String]] = [:]
            var allDeleted: Set<String> = []
            var labelChanges: Set<String> = []
            var latestHistoryId = startHistoryId
            var pageToken: String? = nil

            repeat {
                await quota.waitForBudget(2) // history.list = 2 units per page
                guard !Task.isCancelled else { return false }

                let response = try await api.listHistory(
                    accountID: accountID,
                    startHistoryId: startHistoryId,
                    labelId: nil,
                    pageToken: pageToken,
                    maxResults: 500
                )

                latestHistoryId = response.historyId ?? latestHistoryId
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

            Self.logger.info("syncIncremental: added=\(allAdded.count) deleted=\(allDeleted.count) labelChanges=\(labelChanges.count)")

            // Separate truly new messages (not in local DB) from existing ones.
            // For existing messages that appear in messagesAdded (e.g. label changes),
            // use the labelIds from the history record directly instead of re-fetching.
            let candidateIDs = Array(allAdded.subtracting(allDeleted))
            var existingIDs = Set<String>()
            if !candidateIDs.isEmpty {
                existingIDs = try await db.dbPool.read { db in
                    var result = Set<String>()
                    let chunkSize = 1000
                    for chunkStart in stride(from: 0, to: candidateIDs.count, by: chunkSize) {
                        let chunk = Array(candidateIDs[chunkStart..<min(chunkStart + chunkSize, candidateIDs.count)])
                        let placeholders = chunk.sqlPlaceholders
                        let chunkResult = try Set(String.fetchAll(db, sql:
                            "SELECT gmail_id FROM messages WHERE gmail_id IN (\(placeholders))",
                            arguments: StatementArguments(chunk)
                        ))
                        result.formUnion(chunkResult)
                    }
                    return result
                }
            }
            let trulyNewIDs = candidateIDs.filter { !existingIDs.contains($0) }

            // Report incremental sync progress for large syncs
            let toRefetchCount = labelChanges.subtracting(allDeleted).subtracting(Set(candidateIDs)).count
            let totalRemaining = trulyNewIDs.count + toRefetchCount + allDeleted.count
            await reportProgress(.progress(remaining: totalRemaining))

            // Existing messages from messagesAdded: apply label updates from history data
            let historyLabelUpdates: [(gmailId: String, labelIds: [String])] = candidateIDs
                .filter { existingIDs.contains($0) }
                .compactMap { id in
                    guard let labels = addedMessageLabels[id] else { return nil }
                    return (gmailId: id, labelIds: labels)
                }

            var newMessages: [GmailMessage] = []
            newMessages.reserveCapacity(trulyNewIDs.count)
            if !trulyNewIDs.isEmpty {
                // Fetch with "full" format directly to get headers + body in one call.
                // This avoids a redundant re-fetch that doubles API quota for new messages.
                // Reserve quota per chunk (50 IDs = 250 units) instead of all upfront,
                // which would deadlock when trulyNewIDs.count * 5 exceeds budgetPerMinute.
                let quotaChunkSize = 50
                var failedNewCount = 0
                for chunkStart in stride(from: 0, to: trulyNewIDs.count, by: quotaChunkSize) {
                    let chunk = Array(trulyNewIDs[chunkStart..<min(chunkStart + quotaChunkSize, trulyNewIDs.count)])
                    await quota.waitForBudget(chunk.count * 5)
                    let (fetched, failed) = try await api.getMessages(
                        ids: chunk, accountID: accountID, format: "full"
                    )
                    newMessages.append(contentsOf: fetched)
                    failedNewCount += failed.count
                }
                if failedNewCount > 0 {
                    Self.logger.warning("Delta sync: \(failedNewCount) new message(s) failed to fetch, will retry on next sync")
                }
            }

            // Fetch updated label info for changed messages.
            // "minimal" format is sufficient — we only need id and labelIds.
            let toRefetch = labelChanges.subtracting(allDeleted).subtracting(Set(candidateIDs))
            var labelUpdates: [(gmailId: String, labelIds: [String])] = historyLabelUpdates
            labelUpdates.reserveCapacity(historyLabelUpdates.count + toRefetch.count)
            if !toRefetch.isEmpty {
                let refetchIDs = Array(toRefetch)
                let quotaChunkSize = 50
                var failedRefreshCount = 0
                for chunkStart in stride(from: 0, to: refetchIDs.count, by: quotaChunkSize) {
                    let chunk = Array(refetchIDs[chunkStart..<min(chunkStart + quotaChunkSize, refetchIDs.count)])
                    await quota.waitForBudget(chunk.count * 5)
                    let (refreshed, failed) = try await api.getMessages(
                        ids: chunk, accountID: accountID, format: "minimal"
                    )
                    labelUpdates += refreshed.map { (gmailId: $0.id, labelIds: $0.labelIds ?? []) }
                    failedRefreshCount += failed.count
                }
                if failedRefreshCount > 0 {
                    Self.logger.warning("Delta sync: \(failedRefreshCount) label-refresh message(s) failed to fetch")
                }
            }

            // Filter label updates to messages that exist locally.
            // The initial sync excludes spam/trash, but the History API returns
            // events for ALL messages. Label updates for non-local messages would
            // violate the message_labels FK constraint.
            if !labelUpdates.isEmpty {
                let updateIDs = Array(Set(labelUpdates.map(\.gmailId)))
                let localIDs = try await db.dbPool.read { db in
                    var result = Set<String>()
                    let chunkSize = 1000
                    for chunkStart in stride(from: 0, to: updateIDs.count, by: chunkSize) {
                        let chunk = Array(updateIDs[chunkStart..<min(chunkStart + chunkSize, updateIDs.count)])
                        let placeholders = chunk.sqlPlaceholders
                        let found = try Set(String.fetchAll(db, sql:
                            "SELECT gmail_id FROM messages WHERE gmail_id IN (\(placeholders))",
                            arguments: StatementArguments(chunk)
                        ))
                        result.formUnion(found)
                    }
                    return result
                }
                let before = labelUpdates.count
                labelUpdates = labelUpdates.filter { localIDs.contains($0.gmailId) }
                if labelUpdates.count < before {
                    Self.logger.info("syncIncremental: filtered \(before - labelUpdates.count) label updates for non-local messages")
                }
            }

            // Apply delta to DB
            Self.logger.info("syncIncremental: applying delta — new=\(newMessages.count) deleted=\(allDeleted.count) labelUpdates=\(labelUpdates.count)")
            try await syncer.applyDelta(
                newMessages: newMessages,
                deletedIds: Array(allDeleted),
                labelUpdates: labelUpdates
            )

            // Save historyId and timestamp atomically after all fetches and DB writes
            // succeed. Writing both in one call prevents inconsistent state if the
            // app crashes between them, and ensures a failed sync retries the full
            // history range.
            let capturedHistoryId = latestHistoryId
            await writeSyncState { state in
                state.lastHistoryId = capturedHistoryId
                state.lastSyncAt = Date().timeIntervalSince1970
            }

            // Fire local notifications only if the history actually advanced.
            // If latestHistoryId == startHistoryId, the same range was processed
            // (e.g. empty history page) and notifications would be duplicates.
            if latestHistoryId != startHistoryId {
                await fireNotifications(for: newMessages)
            }

            consecutiveFailures = 0
            return true

        } catch {
            Self.logger.error("syncIncremental failed (failures=\(self.consecutiveFailures)): \(error)")
            if case .tokenRevoked = error as? GoogleAPIError {
                Self.logger.error("Auth failure for \(self.accountID, privacy: .private): tokenRevoked, stopping sync")
                await handleFatalAuthError()
                return false
            } else if case .unauthorized = error as? GoogleAPIError {
                Self.logger.error("Auth failure for \(self.accountID, privacy: .private): unauthorized, stopping sync")
                await handleFatalAuthError()
                return false
            } else if case .httpError(let code, _) = error as? GoogleAPIError, code == 404 || code == 410 {
                // 404 or 410 from history.list means the startHistoryId is expired/invalid.
                // Gmail returns 404 for stale history IDs and 410 (Gone) in some cases.
                // Note: this catch only fires for errors from history.list — getMessages
                // failures (e.g. deleted messages) surface as BatchFetchResult.failedIDs,
                // not thrown errors, so they won't trigger this path.
                Self.logger.warning("History ID expired, restarting full sync")
                await writeSyncState { state in
                    state.initialSyncComplete = false
                    state.initialSyncPageToken = nil
                    state.lastHistoryId = nil
                    state.syncedMessageCount = 0
                }
                // Assign restartTask BEFORE cancelling other tasks so that a
                // concurrent stop() always sees a non-nil restartTask to await.
                // Cancel non-restart tasks inside the task to keep the
                // assignment and cancellation atomic from stop()'s perspective.
                // Do NOT remove from activeEngines — start() will overwrite
                // the entry atomically, avoiding a registry race.
                state = .idle
                restartTask = Task { [weak self] in
                    guard let self else { return }
                    await self.cancelNonRestartTasks()
                    guard !Task.isCancelled else {
                        Self.activeEngines.withLock { _ = $0.removeValue(forKey: self.accountID) }
                        return
                    }
                    // Yield to let any concurrent stop() complete before restarting
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled else {
                        Self.activeEngines.withLock { _ = $0.removeValue(forKey: self.accountID) }
                        return
                    }
                    await self.start()
                }
                return false
            } else {
                Self.logger.error("Incremental sync error: \(error.localizedDescription)")
                if consecutiveFailures < 5 { consecutiveFailures += 1 }
                return false
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
                } else {
                    // Throttle between batches to avoid hammering API/DB
                    try? await Task.sleep(for: .seconds(1))
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

            let (fullMessages, failedBodyIDs) = try await api.getMessages(
                ids: ids, accountID: accountID, format: "full"
            )
            if !failedBodyIDs.isEmpty {
                Self.logger.warning("Body prefetch: \(failedBodyIDs.count) message(s) failed to fetch")
                try await syncer.incrementBodyFetchAttempts(for: failedBodyIDs)
            }
            let updates = fullMessages.map { msg in
                (gmailId: msg.id, html: msg.htmlBody, plain: msg.plainBody)
            }
            try await syncer.updateBodies(updates)

            let remaining = try await db.dbPool.read { db in
                try MailDatabaseQueries.messagesWithoutBodiesCount(in: db)
            }

            await reportProgress(.bodyPrefetch(remaining: remaining))
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
            _pollingOverride = 300 // 5 minutes when backgrounded/unfocused
        } else {
            _pollingOverride = nil // use default 60s
        }
    }

    /// Toggles Pub/Sub-driven backup polling. Cancels and restarts the incremental loop
    /// so the new polling interval takes effect immediately (without waiting for a sleep to expire).
    func setPubSubActive(_ active: Bool) {
        guard pubSubActive != active else { return }
        pubSubActive = active
        Self.logger.info("Pub/Sub active: \(active) — polling interval now \(self.pollingInterval)s")
        // Restart the incremental loop with the new interval
        if state == .monitoring {
            incrementalTask?.cancel()
            startIncrementalLoop()
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
            try await syncer.syncLabels(labels)
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

    /// Filter for inbox messages and parse sender contacts — pure computation, no actor state needed.
    nonisolated private static func prepareNotifications(
        from messages: [GmailMessage]
    ) -> [(msg: GmailMessage, senderName: String)] {
        messages
            .filter { $0.labelIds?.contains(GmailSystemLabel.inbox) == true }
            .prefix(5)
            .map { msg in
                let sender = GmailDataTransformer.parseContactCore(msg.from)
                return (msg: msg, senderName: sender.name)
            }
    }

    @MainActor
    private func fireNotifications(for messages: [GmailMessage]) {
        let prepared = Self.prepareNotifications(from: messages)
        for (msg, senderName) in prepared {
            let priority = notificationPriority(for: msg)
            NotificationService.shared.notifyNewEmail(
                messageId: msg.id,
                threadId: msg.threadId,
                senderName: senderName,
                subject: msg.subject,
                snippet: msg.snippet ?? "",
                accountID: accountID,
                priority: priority
            )
        }
    }

    /// Derive notification priority from classification tags or Gmail label heuristics.
    @MainActor
    private func notificationPriority(for message: GmailMessage) -> EmailNotificationPriority {
        if let tags = EmailClassifier.shared.cachedTags(for: message.id) {
            if tags.hasDeadline { return .urgent }
            if tags.fyiOnly { return .low }
        }
        let labels = message.labelIds ?? []
        if labels.contains("IMPORTANT") { return .urgent }
        if labels.contains("CATEGORY_PROMOTIONS") || labels.contains("CATEGORY_UPDATES") { return .low }
        return .normal
    }

    // MARK: - DB Helpers

    private func readSyncState() async -> AccountSyncStateRecord? {
        try? await db.dbPool.read { db in
            try MailDatabaseQueries.syncState(in: db)
        }
    }

    @discardableResult
    private func writeSyncState(_ update: @Sendable (inout AccountSyncStateRecord) -> Void) async -> Bool {
        do {
            try await db.dbPool.write { db in
                try MailDatabaseQueries.updateSyncState(update, in: db)
            }
            return true
        } catch {
            Self.logger.error("Failed to write sync state: \(error.localizedDescription)")
            return false
        }
    }

    private func reportProgress(_ event: SyncProgressEvent) async {
        await onProgress(event)
    }
}
