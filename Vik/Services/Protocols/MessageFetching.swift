import Foundation

// MARK: - MessageReading

/// Read-only access to Gmail messages, threads, and history.
///
/// Uses `throws(GoogleAPIError)` for typed throws — conforming types can throw
/// `GoogleAPIError` or a subtype (including `Never` for non-throwing mocks).
@MainActor
protocol MessageReading: Sendable {
    @concurrent func listMessages(accountID: String, labelIDs: [String], query: String?, pageToken: String?, maxResults: Int) async throws(GoogleAPIError) -> GmailMessageListResponse
    @concurrent func getMessage(id: String, accountID: String, format: String) async throws(GoogleAPIError) -> GmailMessage
    @concurrent func getMessages(ids: [String], accountID: String, format: String) async throws(GoogleAPIError) -> (messages: [GmailMessage], failedIDs: [String])
    @concurrent func getThread(id: String, accountID: String) async throws(GoogleAPIError) -> GmailThread
    @concurrent func listHistory(accountID: String, startHistoryId: String, labelId: String?, pageToken: String?, maxResults: Int) async throws(GoogleAPIError) -> GmailHistoryListResponse
}

// MARK: - MessageMutating

/// Write operations on Gmail messages (read-state, labels, trash, archive, spam, delete).
@MainActor
protocol MessageMutating: Sendable {
    @concurrent func markAsRead(id: String, accountID: String) async throws(GoogleAPIError)
    @concurrent func markAsUnread(id: String, accountID: String) async throws(GoogleAPIError)
    @concurrent func setStarred(_ starred: Bool, id: String, accountID: String) async throws(GoogleAPIError)
    @discardableResult
    @concurrent func trashMessage(id: String, accountID: String) async throws(GoogleAPIError) -> GmailMessage
    @discardableResult
    @concurrent func untrashMessage(id: String, accountID: String) async throws(GoogleAPIError) -> GmailMessage
    @concurrent func archiveMessage(id: String, accountID: String) async throws(GoogleAPIError)
    @concurrent func spamMessage(id: String, accountID: String) async throws(GoogleAPIError)
    @concurrent func deleteMessagePermanently(id: String, accountID: String) async throws(GoogleAPIError)
    @discardableResult
    @concurrent func modifyLabels(id: String, add: [String], remove: [String], accountID: String) async throws(GoogleAPIError) -> GmailMessage
    @concurrent func batchModifyLabels(ids: [String], add addLabelIds: [String], remove removeLabelIds: [String], accountID: String) async throws(GoogleAPIError)
}

// MARK: - AttachmentFetching

/// Downloads raw attachment data for a given message.
@MainActor
protocol AttachmentFetching: Sendable {
    @concurrent func getAttachment(messageID: String, attachmentID: String, accountID: String) async throws(GoogleAPIError) -> Data
}

// MARK: - MailboxManaging

/// Mailbox-level operations: bulk folder clearing and account profile.
@MainActor
protocol MailboxManaging: Sendable {
    @concurrent func emptyTrash(accountID: String) async throws(GoogleAPIError)
    @concurrent func emptySpam(accountID: String) async throws(GoogleAPIError)
    @concurrent func getProfile(accountID: String) async throws(GoogleAPIError) -> GmailProfile
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
    @concurrent func getProfile(accountID: String) async throws(GoogleAPIError) -> GmailProfile {
        try await GmailProfileService.shared.getProfile(accountID: accountID)
    }
}
