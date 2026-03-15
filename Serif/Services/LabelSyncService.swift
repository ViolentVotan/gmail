import Foundation

/// Handles label loading, sendAs aliases, and category unread counts.
/// Uses ETag-based caching to avoid redundant API responses (304 Not Modified).
@MainActor
final class LabelSyncService {
    static let shared = LabelSyncService()
    private init() {}

    /// Cached ETag for label list requests — enables 304 Not Modified responses.
    private var labelsETag: String?

    /// Loads labels from the API with ETag caching.
    /// Returns cached labels on 304 Not Modified, fresh labels on 200.
    func loadLabels(
        accountID: String,
        currentLabels: [GmailLabel]
    ) async -> (labels: [GmailLabel], error: String?) {
        do {
            let result = try await GmailLabelService.shared.listLabels(
                etag: labelsETag, accountID: accountID
            )
            guard let (fresh, responseETag) = result else {
                // 304 Not Modified — return cached labels
                return (currentLabels, nil)
            }
            labelsETag = responseETag
            return (fresh, nil)
        } catch {
            if currentLabels.isEmpty {
                return (currentLabels, error.localizedDescription)
            }
            return (currentLabels, nil)
        }
    }

    /// Loads the sendAs aliases for the given account.
    func loadSendAs(accountID: String) async -> (aliases: [GmailSendAs], error: String?) {
        do {
            let aliases = try await GmailProfileService.shared.listSendAs(accountID: accountID)
            return (aliases, nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    /// Loads unread counts per inbox category via a single listLabels() call with ETag caching.
    /// Returns empty counts on 304 Not Modified (caller should keep existing counts).
    private var categoryETag: String?

    func loadCategoryUnreadCounts(accountID: String) async -> [InboxCategory: Int]? {
        guard !accountID.isEmpty else { return [:] }
        do {
            let result = try await GmailLabelService.shared.listLabels(
                etag: categoryETag, accountID: accountID
            )
            guard let (labels, responseETag) = result else {
                // 304 Not Modified — caller should keep existing counts
                return nil
            }
            categoryETag = responseETag
            let labelsByID = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
            var counts: [InboxCategory: Int] = [:]
            for category in InboxCategory.allCases {
                let labelID = (category == .all) ? GmailSystemLabel.inbox : category.rawValue
                if let label = labelsByID[labelID], let unread = label.messagesUnread, unread > 0 {
                    counts[category] = unread
                }
            }
            return counts
        } catch {
            return [:]
        }
    }
}
