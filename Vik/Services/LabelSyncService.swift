import Foundation

/// Handles label loading, sendAs aliases, and category unread counts.
/// Uses ETag-based caching to avoid redundant API responses (304 Not Modified).
/// Both `loadLabels` and `loadCategoryUnreadCounts` share a single `labels.list`
/// API call per account — the first call fetches, the second reuses the cached
/// response (valid for 5 seconds to cover back-to-back calls in the same cycle).
@MainActor
final class LabelSyncService {
    static let shared = LabelSyncService()
    private init() {}

    /// Cached ETag for label list requests — keyed by accountID for multi-account support.
    /// Shared by both loadLabels and loadCategoryUnreadCounts since they hit the same endpoint.
    private var etag: [String: String] = [:]

    /// Short-lived cache of the last successful labels.list response per account.
    /// Prevents duplicate API calls when loadLabels() and loadCategoryUnreadCounts()
    /// are called concurrently (e.g., via `async let` in AppCoordinator).
    private var lastFetch: [String: (labels: [GmailLabel], fetchedAt: Date)] = [:]

    /// Cache validity window — covers back-to-back calls within the same sync cycle.
    private let cacheValiditySeconds: TimeInterval = 5

    // MARK: - Labels

    /// Loads labels from the API with ETag caching.
    /// Returns cached labels on 304 Not Modified, fresh labels on 200.
    func loadLabels(
        accountID: String,
        currentLabels: [GmailLabel]
    ) async -> (labels: [GmailLabel], error: String?) {
        do {
            let labels = try await fetchLabelsIfNeeded(accountID: accountID)
            guard let labels else {
                // 304 Not Modified — return cached labels
                return (currentLabels, nil)
            }
            return (labels, nil)
        } catch {
            if currentLabels.isEmpty {
                return (currentLabels, error.localizedDescription)
            }
            return (currentLabels, nil)
        }
    }

    // MARK: - Send As

    /// Loads the sendAs aliases for the given account.
    func loadSendAs(accountID: String) async -> (aliases: [GmailSendAs], error: String?) {
        do {
            let aliases = try await GmailProfileService.shared.listSendAs(accountID: accountID)
            return (aliases, nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    // MARK: - Category Unread Counts

    /// Extracts unread counts per inbox category from cached or freshly-fetched labels.
    /// Returns nil on 304 Not Modified (caller should keep existing counts).
    func loadCategoryUnreadCounts(accountID: String) async -> [InboxCategory: Int]? {
        guard !accountID.isEmpty else { return [:] }
        do {
            let labels = try await fetchLabelsIfNeeded(accountID: accountID)
            guard let labels else {
                // 304 Not Modified — caller should keep existing counts
                return nil
            }
            return extractCategoryCounts(from: labels)
        } catch {
            return [:]
        }
    }

    // MARK: - ETag Management

    /// Clears cached ETags and fetch cache for the given account (e.g. on account removal or sign-out).
    func clearETags(for accountID: String) {
        etag.removeValue(forKey: accountID)
        lastFetch.removeValue(forKey: accountID)
    }

    // MARK: - Private

    /// Fetches labels from the API, reusing a recent cached response if available.
    /// Returns nil when the server responds 304 Not Modified (ETag match).
    private func fetchLabelsIfNeeded(accountID: String) async throws -> [GmailLabel]? {
        // Reuse a recent fetch from the same sync cycle
        if let cached = lastFetch[accountID],
           Date().timeIntervalSince(cached.fetchedAt) < cacheValiditySeconds {
            return cached.labels
        }

        let result = try await GmailLabelService.shared.listLabels(
            etag: etag[accountID], accountID: accountID
        )
        guard let (fresh, responseETag) = result else {
            // 304 Not Modified
            return nil
        }
        etag[accountID] = responseETag
        lastFetch[accountID] = (labels: fresh, fetchedAt: Date())
        return fresh
    }

    /// Extracts per-category unread counts from a labels response.
    private func extractCategoryCounts(from labels: [GmailLabel]) -> [InboxCategory: Int] {
        let labelsByID = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
        var counts: [InboxCategory: Int] = [:]
        for category in InboxCategory.allCases {
            let labelID = (category == .all) ? GmailSystemLabel.inbox : category.rawValue
            if let label = labelsByID[labelID], let unread = label.messagesUnread, unread > 0 {
                counts[category] = unread
            }
        }
        return counts
    }
}
