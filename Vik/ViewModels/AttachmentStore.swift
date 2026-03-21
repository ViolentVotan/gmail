import Foundation
import Observation

// MARK: - Glob Matching

extension String {
    /// Matches a simple glob pattern (supports `*` as wildcard, case-insensitive).
    func matchesGlob(_ pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        let regexPattern = "^" + escaped.replacingOccurrences(of: "\\*", with: ".*") + "$"
        return range(of: regexPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// MARK: - IndexingStats

struct IndexingStats: Equatable, Sendable {
    var total: Int = 0
    var indexed: Int = 0
    var pending: Int = 0
    var failed: Int = 0
}

// MARK: - AttachmentStore

@Observable
@MainActor
final class AttachmentStore {

    // MARK: - State

    var searchQuery = "" {
        didSet {
            debouncedSearch()
        }
    }
    var searchResults: [AttachmentSearchResult] = [] {
        didSet { scheduleRecompute() }
    }
    var allAttachments: [IndexedAttachment] = [] {
        didSet { scheduleRecompute() }
    }
    var stats = IndexingStats()
    var isSearching = false
    var filterFileType: Attachment.FileType? {
        didSet { scheduleRecompute() }
    }
    var filterDirection: IndexedAttachment.Direction? {
        didSet { scheduleRecompute() }
    }
    var exclusionRules: [String] = [] {
        didSet { scheduleRecompute() }
    }

    /// Cached result of filtering, exclusion, and deduplication. Updated only when inputs change.
    private(set) var displayedAttachments: [AttachmentSearchResult] = []

    /// True when a refresh was requested while the attachments folder was not visible.
    /// Flushed by `refreshIfNeeded()` on folder navigation.
    private(set) var needsRefresh = false

    // MARK: - Dependencies

    @ObservationIgnored private let database: AttachmentDatabase
    @ObservationIgnored private let searchService: AttachmentSearchService
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    @ObservationIgnored var accountID: String = ""

    var isIndexing: Bool { stats.pending > 0 }

    // MARK: - Cache Recomputation

    private func scheduleRecompute() {
        recomputeDisplayedAttachments()
    }

    private func recomputeDisplayedAttachments() {
        let query = searchQuery
        let all = allAttachments
        let results = searchResults
        let fileType = filterFileType
        let direction = filterDirection
        let rules = exclusionRules

        recomputeTask?.cancel()
        recomputeTask = Task {
            let filtered = Self.filterAttachments(
                query: query, allAttachments: all, searchResults: results,
                fileType: fileType, direction: direction, exclusionRules: rules
            )
            guard !Task.isCancelled else { return }
            displayedAttachments = filtered
        }
    }

    /// Pure filtering — nonisolated so it doesn't block the main actor.
    nonisolated private static func filterAttachments(
        query: String,
        allAttachments: [IndexedAttachment],
        searchResults: [AttachmentSearchResult],
        fileType: Attachment.FileType?,
        direction: IndexedAttachment.Direction?,
        exclusionRules: [String]
    ) -> [AttachmentSearchResult] {
        var results = query.isEmpty
            ? allAttachments.map {
                AttachmentSearchResult(id: $0.id, attachment: $0, score: 1.0, matchSource: .fts)
            }
            : searchResults

        if let fileType {
            results = results.filter { $0.attachment.fileType == fileType.rawValue }
        }
        if let direction {
            results = results.filter { $0.attachment.direction == direction }
        }
        if !exclusionRules.isEmpty {
            results = results.filter { r in
                !exclusionRules.contains(where: { r.attachment.filename.matchesGlob($0) })
            }
        }
        var seen = Set<String>()
        results = results.filter { r in
            let key = "\(r.attachment.filename)_\(r.attachment.size)"
            return seen.insert(key).inserted
        }
        return results
    }

    // MARK: - Init

    init(database: AttachmentDatabase = .shared) {
        self.database = database
        self.searchService = AttachmentSearchService(database: database)
    }

    isolated deinit {
        searchTask?.cancel()
        debounceTask?.cancel()
        recomputeTask?.cancel()
    }

    // MARK: - Search Debounce

    private func debouncedSearch() {
        debounceTask?.cancel()
        let query = searchQuery
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            performSearch(query: query)
        }
    }

    // MARK: - Refresh

    func refresh() async {
        loadExclusionRules()
        let newAttachments = await database.allAttachments(limit: 5000, offset: 0, accountID: accountID)
        let raw = await database.stats(accountID: accountID)
        let newStats = IndexingStats(
            total: raw.total,
            indexed: raw.indexed,
            pending: raw.pending,
            failed: raw.failed
        )
        // Skip expensive array replacement if data is identical
        if newAttachments.map(\.id) != allAttachments.map(\.id) {
            allAttachments = newAttachments
        }
        stats = newStats
        needsRefresh = false
    }

    /// Marks that a refresh is needed but defers it until the attachments folder is visible.
    func setNeedsRefresh() {
        needsRefresh = true
    }

    /// Called when the user navigates to the attachments folder — flushes a pending refresh.
    func refreshIfNeeded() async {
        guard needsRefresh else { return }
        await refresh()
    }

    // MARK: - Exclusion Rules

    func loadExclusionRules() {
        exclusionRules = UserDefaults.standard.stringArray(forKey: UserDefaultsKey.attachmentExclusionRules(accountID)) ?? []
    }

    func saveExclusionRules() {
        UserDefaults.standard.set(exclusionRules, forKey: UserDefaultsKey.attachmentExclusionRules(accountID))
    }

    func addExclusionRule(_ pattern: String) {
        guard !pattern.isEmpty, !exclusionRules.contains(pattern) else { return }
        exclusionRules.append(pattern)
        saveExclusionRules()
    }

    func removeExclusionRule(_ pattern: String) {
        exclusionRules.removeAll { $0 == pattern }
        saveExclusionRules()
    }

    // MARK: - Search

    private func performSearch(query: String) {
        searchTask?.cancel()
        searchTask = Task {
            isSearching = true
            defer { isSearching = false }

            guard !Task.isCancelled else { return }
            let results = await searchService.search(query: query, accountID: accountID)
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }
}
