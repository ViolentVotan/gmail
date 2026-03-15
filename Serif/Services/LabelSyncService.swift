import Foundation

/// Handles label loading, sendAs aliases, and category unread counts.
@MainActor
final class LabelSyncService {
    static let shared = LabelSyncService()
    private init() {}

    /// Loads labels from the API.
    /// Returns the labels and an optional error message.
    func loadLabels(
        accountID: String,
        currentLabels: [GmailLabel]
    ) async -> (labels: [GmailLabel], error: String?) {
        var labels = currentLabels
        do {
            let fresh = try await GmailLabelService.shared.listLabels(accountID: accountID)
            labels = fresh
            return (labels, nil)
        } catch {
            if labels.isEmpty {
                return (labels, error.localizedDescription)
            }
            return (labels, nil)
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

    /// Loads unread counts per inbox category via a single listLabels() call.
    func loadCategoryUnreadCounts(accountID: String) async -> [InboxCategory: Int] {
        guard !accountID.isEmpty else { return [:] }
        do {
            let labels = try await GmailLabelService.shared.listLabels(accountID: accountID)
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
