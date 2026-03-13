import SwiftUI

/// Handles message fetching, pagination, and in-memory caching for a mailbox.
/// Owns the internal cache state; the MailboxViewModel orchestrates the
/// fetch flow and applies results to its @Observable-tracked properties.
@MainActor
final class MessageFetchService {

    // MARK: - Injected dependencies

    private let api: MessageFetching

    // MARK: - Dependencies (set by MailboxViewModel)

    /// Called to convert a GmailMessage into an Email for background analysis.
    var makeEmail: ((GmailMessage) -> Email)?
    /// Reference to the attachment indexer (if configured).
    var attachmentIndexer: AttachmentIndexer?
    /// Account ID used when persisting AI classification tags.
    var accountID: String = ""
    /// Reference to mail database for writing classification tags.
    var mailDatabase: MailDatabase?

    // MARK: - Internal cache state

    /// In-memory cache of fetched messages (metadata format) keyed by message ID.
    var messageCache: [String: GmailMessage] = [:]
    let pageSize = 50

    init(api: MessageFetching = GmailMessageService.shared) {
        self.api = api
    }

    /// Tracks the current fetch task so it can be cancelled when a new one starts.
    private var activeFetchTask: Task<Void, Never>?
    /// Monotonically increasing token to discard stale results from races.
    private var fetchGeneration: UInt64 = 0

    // MARK: - Task management

    func cancelActiveFetch() {
        activeFetchTask?.cancel()
        activeFetchTask = nil
    }

    func setActiveFetchTask(_ task: Task<Void, Never>) {
        activeFetchTask = task
    }

    func awaitActiveFetch() async {
        await activeFetchTask?.value
    }

    func nextGeneration() -> UInt64 {
        fetchGeneration &+= 1
        return fetchGeneration
    }

    var currentGeneration: UInt64 { fetchGeneration }

    func isStale(generation: UInt64) -> Bool {
        Task.isCancelled || generation != fetchGeneration
    }

    // MARK: - API fetch helpers

    /// Fetches the message list from the API.
    func listMessages(
        accountID: String,
        currentLabelIDs: [String],
        currentQuery: String?,
        pageToken: String?
    ) async throws -> GmailMessageListResponse {
        try await api.listMessages(
            accountID: accountID,
            labelIDs:  currentLabelIDs,
            query:     currentQuery,
            pageToken: pageToken,
            maxResults: pageSize
        )
    }

    /// Fetches full metadata for message IDs not already in the cache.
    /// Returns the newly fetched messages.
    func fetchMissingMessages(
        refs: [GmailMessageRef],
        accountID: String
    ) async throws -> [GmailMessage] {
        let idsToFetch = refs.map(\.id).filter { messageCache[$0] == nil }
        guard !idsToFetch.isEmpty else { return [] }
        let fetched = try await api.getMessages(
            ids: idsToFetch,
            accountID: accountID,
            format: "metadata"
        )
        for msg in fetched { messageCache[msg.id] = msg }
        return fetched
    }

    /// Resolves message refs to full GmailMessage objects using the cache.
    func resolveFromCache(_ refs: [GmailMessageRef]) -> [GmailMessage] {
        refs.compactMap { messageCache[$0.id] }
    }

    // MARK: - Background analysis (subscriptions + attachments)

    func analyzeInBackground(_ msgs: [GmailMessage]) {
        guard !msgs.isEmpty, let makeEmail = makeEmail else { return }
        SubscriptionsStore.shared.analyze(msgs.map { makeEmail($0) })
        if let indexer = attachmentIndexer {
            let withAttachments = msgs.filter { $0.hasPartsWithFilenames }
            if !withAttachments.isEmpty {
                Task { await indexer.registerFromMetadata(messages: withAttachments) }
            }
        }
        // AI classification — runs after subscription detection
        let emails = msgs.compactMap { makeEmail($0) }
        let db = mailDatabase
        Task {
            await EmailClassifier.shared.classifyBatch(emails, db: db)
        }
    }

    // MARK: - Batch verify (stale detection)

    /// Verifies a batch of message IDs concurrently, tolerating individual 404 errors.
    /// Returns a dictionary of successfully fetched messages keyed by ID.
    /// Messages that return 404 (deleted) are simply absent from the result.
    func verifyMessages(
        ids: [String],
        accountID: String,
        api: MessageFetching
    ) async -> [String: GmailMessage] {
        guard !ids.isEmpty else { return [:] }
        // Prefer batch API for efficiency (single HTTP call vs N)
        do {
            let messages = try await api.getMessages(ids: ids, accountID: accountID, format: "minimal")
            var result: [String: GmailMessage] = [:]
            for msg in messages { result[msg.id] = msg }
            return result
        } catch {
            #if DEBUG
            print("[Serif] Batch verify failed, falling back to individual fetches: \(error)")
            #endif
            // Fall back to individual fetches if batch fails
            let maxConcurrency = 10
            return await withTaskGroup(of: (String, GmailMessage?).self) { group in
                var idIterator = ids.makeIterator()
                var result: [String: GmailMessage] = [:]

                // Seed initial batch
                for _ in 0..<min(maxConcurrency, ids.count) {
                    if let id = idIterator.next() {
                        group.addTask {
                            let msg = try? await api.getMessage(id: id, accountID: accountID, format: "minimal")
                            return (id, msg)
                        }
                    }
                }

                // As each completes, add the next
                for await (id, msg) in group {
                    if let msg { result[id] = msg }
                    if let nextID = idIterator.next() {
                        group.addTask {
                            let msg = try? await api.getMessage(id: nextID, accountID: accountID, format: "minimal")
                            return (nextID, msg)
                        }
                    }
                }
                return result
            }
        }
    }

    // MARK: - Reset (for account switch)

    func resetState() {
        messageCache = [:]
    }
}
