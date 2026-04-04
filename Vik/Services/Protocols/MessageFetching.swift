import Foundation

// MARK: - MessageReading

/// Read-only access to Gmail messages, threads, and history.
///
/// Uses `throws(GmailAPIError)` for typed throws — conforming types can throw
/// `GmailAPIError` or a subtype (including `Never` for non-throwing mocks).
@MainActor
protocol MessageReading: Sendable {
    @concurrent func listMessages(accountID: String, labelIDs: [String], query: String?, pageToken: String?, maxResults: Int) async throws(GmailAPIError) -> GmailMessageListResponse
    @concurrent func getMessage(id: String, accountID: String, format: String) async throws(GmailAPIError) -> GmailMessage
    @concurrent func getMessages(ids: [String], accountID: String, format: String) async throws(GmailAPIError) -> (messages: [GmailMessage], failedIDs: [String])
    @concurrent func getThread(id: String, accountID: String) async throws(GmailAPIError) -> GmailThread
    @concurrent func listHistory(accountID: String, startHistoryId: String, labelId: String?, pageToken: String?, maxResults: Int) async throws(GmailAPIError) -> GmailHistoryListResponse
}

// MARK: - MessageMutating

/// Write operations on Gmail messages (read-state, labels, trash, archive, spam, delete).
@MainActor
protocol MessageMutating: Sendable {
    @concurrent func markAsRead(id: String, accountID: String) async throws(GmailAPIError)
    @concurrent func markAsUnread(id: String, accountID: String) async throws(GmailAPIError)
    @concurrent func setStarred(_ starred: Bool, id: String, accountID: String) async throws(GmailAPIError)
    @discardableResult
    @concurrent func trashMessage(id: String, accountID: String) async throws(GmailAPIError) -> GmailMessage
    @discardableResult
    @concurrent func untrashMessage(id: String, accountID: String) async throws(GmailAPIError) -> GmailMessage
    @concurrent func archiveMessage(id: String, accountID: String) async throws(GmailAPIError)
    @concurrent func spamMessage(id: String, accountID: String) async throws(GmailAPIError)
    @concurrent func deleteMessagePermanently(id: String, accountID: String) async throws(GmailAPIError)
    @discardableResult
    @concurrent func modifyLabels(id: String, add: [String], remove: [String], accountID: String) async throws(GmailAPIError) -> GmailMessage
    @concurrent func batchModifyLabels(ids: [String], add addLabelIds: [String], remove removeLabelIds: [String], accountID: String) async throws(GmailAPIError)
}

// MARK: - AttachmentFetching

/// Downloads raw attachment data for a given message.
@MainActor
protocol AttachmentFetching: Sendable {
    @concurrent func getAttachment(messageID: String, attachmentID: String, accountID: String) async throws(GmailAPIError) -> Data
}

// MARK: - MailboxManaging

/// Mailbox-level operations: bulk folder clearing and account profile.
@MainActor
protocol MailboxManaging: Sendable {
    @concurrent func emptyTrash(accountID: String) async throws(GmailAPIError)
    @concurrent func emptySpam(accountID: String) async throws(GmailAPIError)
    @concurrent func getProfile(accountID: String) async throws(GmailAPIError) -> GmailProfile
}

// MARK: - MessageFetching (composition)

/// Full Gmail message API surface — backward-compatible alias for protocol composition.
///
/// Callers that only need a subset of operations should narrow their dependency to
/// `MessageReading`, `MessageMutating`, `AttachmentFetching`, or `MailboxManaging`.
typealias MessageFetching = MessageReading & MessageMutating & AttachmentFetching & MailboxManaging

// MARK: - GmailMessageService conformance

extension GmailMessageService: MessageReading {}
extension GmailMessageService: MessageMutating {}
extension GmailMessageService: AttachmentFetching {}
extension GmailMessageService: MailboxManaging {
    @concurrent func getProfile(accountID: String) async throws(GmailAPIError) -> GmailProfile {
        try await GmailProfileService.shared.getProfile(accountID: accountID)
    }
}
