import Foundation

/// Abstracts the Gmail message API surface so services and view models
/// can be tested with mock implementations.
///
/// Uses `throws(GmailAPIError)` for typed throws — conforming types can throw
/// `GmailAPIError` or a subtype (including `Never` for non-throwing mocks).
/// See SE-0413 for subtyping rules.
@MainActor
protocol MessageFetching: Sendable {
    @concurrent func listMessages(accountID: String, labelIDs: [String], query: String?, pageToken: String?, maxResults: Int) async throws(GmailAPIError) -> GmailMessageListResponse
    @concurrent func getMessage(id: String, accountID: String, format: String) async throws(GmailAPIError) -> GmailMessage
    @concurrent func getMessages(ids: [String], accountID: String, format: String) async throws(GmailAPIError) -> [GmailMessage]
    @concurrent func listHistory(accountID: String, startHistoryId: String, labelId: String?, pageToken: String?, maxResults: Int) async throws(GmailAPIError) -> GmailHistoryListResponse
    @concurrent func markAsRead(id: String, accountID: String) async throws(GmailAPIError)
    @concurrent func setStarred(_ starred: Bool, id: String, accountID: String) async throws(GmailAPIError)
    @discardableResult
    @concurrent func trashMessage(id: String, accountID: String) async throws(GmailAPIError) -> GmailMessage
    @concurrent func archiveMessage(id: String, accountID: String) async throws(GmailAPIError)
    @concurrent func markAsUnread(id: String, accountID: String) async throws(GmailAPIError)
    @discardableResult
    @concurrent func untrashMessage(id: String, accountID: String) async throws(GmailAPIError) -> GmailMessage
    @concurrent func deleteMessagePermanently(id: String, accountID: String) async throws(GmailAPIError)
    @concurrent func spamMessage(id: String, accountID: String) async throws(GmailAPIError)
    @discardableResult
    @concurrent func modifyLabels(id: String, add: [String], remove: [String], accountID: String) async throws(GmailAPIError) -> GmailMessage
    @concurrent func getThread(id: String, accountID: String) async throws(GmailAPIError) -> GmailThread
    @concurrent func getAttachment(messageID: String, attachmentID: String, accountID: String) async throws(GmailAPIError) -> Data
    @concurrent func emptyTrash(accountID: String) async throws(GmailAPIError)
    @concurrent func emptySpam(accountID: String) async throws(GmailAPIError)
}

// MARK: - GmailMessageService conformance

extension GmailMessageService: MessageFetching {}
