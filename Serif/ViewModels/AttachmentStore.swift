import Foundation
import Combine

// MARK: - IndexingStats

struct IndexingStats: Equatable {
    var total: Int = 0
    var indexed: Int = 0
    var pending: Int = 0
    var failed: Int = 0
}

// MARK: - AttachmentStore

@MainActor
final class AttachmentStore: ObservableObject {

    // MARK: - Published State

    @Published var searchQuery = ""
    @Published var searchResults: [AttachmentSearchResult] = []
    @Published var allAttachments: [IndexedAttachment] = []
    @Published var stats = IndexingStats()
    @Published var isSearching = false
    @Published var filterFileType: Attachment.FileType?
    @Published var filterDirection: IndexedAttachment.Direction?

    // MARK: - Dependencies

    private let database: AttachmentDatabase
    private let searchService: AttachmentSearchService
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    var indexer: AttachmentIndexer?

    // MARK: - Computed

    var displayedAttachments: [AttachmentSearchResult] {
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
        return results
    }

    var isIndexing: Bool { stats.pending > 0 }

    // MARK: - Init

    init(database: AttachmentDatabase = .shared) {
        self.database = database
        self.searchService = AttachmentSearchService(database: database)
        setupSearchDebounce()
    }

    // MARK: - Search Debounce

    private func setupSearchDebounce() {
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] query in
                self?.performSearch(query: query)
            }
            .store(in: &cancellables)
    }

    // MARK: - Refresh

    func refresh() {
        allAttachments = database.allAttachments(limit: 200, offset: 0)
        let raw = database.stats()
        stats = IndexingStats(
            total: raw.total,
            indexed: raw.indexed,
            pending: raw.pending,
            failed: raw.failed
        )
    }

    // MARK: - Search

    private func performSearch(query: String) {
        searchTask?.cancel()
        searchTask = Task {
            isSearching = true
            defer { isSearching = false }

            guard !Task.isCancelled else { return }
            let results = searchService.search(query: query)
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }
}
