private import os
import SwiftUI

/// Handles incremental delta sync via the Gmail History API.
final class HistorySyncService {

    nonisolated private static let logger = Logger(subsystem: "com.vikingz.serif", category: "HistorySync")

    private let api: MessageFetching

    init(api: MessageFetching = GmailMessageService.shared) {
        self.api = api
    }

    /// Result of a successful history sync operation.
    struct SyncResult {
        var deletedIDs: Set<String> = []
        var newMessages: [GmailMessage] = []
        var refreshedMessages: [GmailMessage] = []
        var latestHistoryId: String?
        var succeeded: Bool = false
        var error: String?
    }

    /// Attempts incremental sync using Gmail History API.
    /// - Parameters:
    ///   - accountID: The account to sync.
    ///   - startHistoryId: The history ID to start syncing from.
    ///   - labelId: Optional label to filter history by.
    ///   - existingMessageIDs: IDs of messages currently displayed, used to avoid
    ///     re-fetching messages we already have and to scope label-change refreshes.
    /// Returns a `SyncResult` with the changes to apply.
    func syncViaHistory(
        accountID: String,
        startHistoryId: String,
        labelId: String? = nil,
        existingMessageIDs: Set<String> = []
    ) async -> SyncResult {
        var result = SyncResult()

        do {
            var allAdded: [String] = []
            var allDeleted: Set<String> = []
            var labelChanges: Set<String> = []
            var latestHistoryId = startHistoryId
            var pageToken: String? = nil

            repeat {
                let response = try await api.listHistory(
                    accountID: accountID,
                    startHistoryId: startHistoryId,
                    labelId: labelId,
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

            result.deletedIDs = allDeleted
            result.latestHistoryId = latestHistoryId

            // Fetch new messages (not already displayed and not deleted)
            let newIDs = allAdded.filter { !existingMessageIDs.contains($0) && !allDeleted.contains($0) }

            if !newIDs.isEmpty {
                let fetched = try await api.getMessages(
                    ids: newIDs, accountID: accountID, format: "metadata"
                )
                // Only include messages that still belong to the current folder.
                // A message may appear in messagesAdded but then get moved/trashed
                // before we sync, so its labels no longer match.
                result.newMessages = fetched
                    .filter { msg in
                        guard let labelId else { return true }
                        return msg.labelIds?.contains(labelId) == true
                    }
                    .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

                // Fire local notifications for new inbox messages (rate-limited to 5 per sync)
                let inboxMessages = result.newMessages
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

            // Re-fetch messages with label changes to update their labelIds
            // Only refresh messages that are currently displayed and weren't just added/deleted
            let toRefetch = labelChanges.subtracting(allDeleted).subtracting(Set(newIDs)).filter { existingMessageIDs.contains($0) }
            if !toRefetch.isEmpty {
                let refreshed = try await api.getMessages(
                    ids: Array(toRefetch), accountID: accountID, format: "metadata"
                )
                result.refreshedMessages = refreshed
            }

            result.succeeded = true
            return result

        } catch {
            if case .httpError(let code, _) = error, code == 404 {
                // historyId expired — fall back to full refresh
                return SyncResult(succeeded: false)
            }
            // Rate-limit (429), server errors (5xx), and other API errors are retriable —
            // mark as failed so the caller shows a stale-data indicator rather than
            // silently swallowing the error.
            Self.logger.error("API error during sync: \(error.localizedDescription, privacy: .public)")
            result.succeeded = false
            result.error = error.localizedDescription
            return result
        }
    }

}
