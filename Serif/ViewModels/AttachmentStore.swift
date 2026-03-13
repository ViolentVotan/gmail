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
            recomputeDisplayedAttachments()
        }
    }
    var searchResults: [AttachmentSearchResult] = [] {
        didSet { recomputeDisplayedAttachments() }
    }
    var allAttachments: [IndexedAttachment] = [] {
        didSet { recomputeDisplayedAttachments() }
    }
    var stats = IndexingStats()
    var isSearching = false
    var filterFileType: Attachment.FileType? {
        didSet { recomputeDisplayedAttachments() }
    }
    var filterDirection: IndexedAttachment.Direction? {
        didSet { recomputeDisplayedAttachments() }
    }
    var exclusionRules: [String] = [] {
        didSet { recomputeDisplayedAttachments() }
    }

    /// Cached result of filtering, exclusion, and deduplication. Updated only when inputs change.
    private(set) var displayedAttachments: [AttachmentSearchResult] = []

    // MARK: - Dependencies

    @ObservationIgnored private let database: AttachmentDatabase
    @ObservationIgnored private let searchService: AttachmentSearchService
    @ObservationIgnored nonisolated(unsafe) private var searchTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var debounceTask: Task<Void, Never>?
    @ObservationIgnored var accountID: String = ""

    @ObservationIgnored var indexer: AttachmentIndexer?

    var isIndexing: Bool { stats.pending > 0 }

    // MARK: - Cache Recomputation

    private func recomputeDisplayedAttachments() {
        var results = searchQuery.isEmpty
            ? allAttachments.map {
                AttachmentSearchResult(id: $0.id, attachment: $0, score: 1.0, matchSource: .fts)
            }
            : searchResults

        if let fileType = filterFileType {
            results = results.filter { $0.attachment.fileType == fileType.rawValue }
        }
        if let direction = filterDirection {
            results = results.filter { $0.attachment.direction == direction }
        }

        // Apply exclusion rules
        if !exclusionRules.isEmpty {
            results = results.filter { r in
                !exclusionRules.contains(where: { r.attachment.filename.matchesGlob($0) })
            }
        }

        // Deduplicate by filename + size (same file attached to multiple emails)
        var seen = Set<String>()
        results = results.filter { r in
            let key = "\(r.attachment.filename)_\(r.attachment.size)"
            return seen.insert(key).inserted
        }
        displayedAttachments = results
    }

    // MARK: - Init

    init(database: AttachmentDatabase = .shared) {
        self.database = database
        self.searchService = AttachmentSearchService(database: database)
    }

    deinit {
        searchTask?.cancel()
        debounceTask?.cancel()
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
        allAttachments = await database.allAttachments(limit: 5000, offset: 0, accountID: accountID)
        let raw = await database.stats(accountID: accountID)
        stats = IndexingStats(
            total: raw.total,
            indexed: raw.indexed,
            pending: raw.pending,
            failed: raw.failed
        )
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
