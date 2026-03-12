import Foundation

/// Abstracts the Gmail message API surface so services and view models
/// can be tested with mock implementations.
@MainActor
protocol MessageFetching: Sendable {
    @concurrent func listMessages(accountID: String, labelIDs: [String], query: String?, pageToken: String?, maxResults: Int) async throws -> GmailMessageListResponse
    @concurrent func getMessage(id: String, accountID: String, format: String) async throws -> GmailMessage
    @concurrent func getMessages(ids: [String], accountID: String, format: String) async throws(GmailAPIError) -> [GmailMessage]
    @concurrent func listHistory(accountID: String, startHistoryId: String, labelId: String?, pageToken: String?, maxResults: Int) async throws -> GmailHistoryListResponse
    @concurrent func markAsRead(id: String, accountID: String) async throws
    @concurrent func setStarred(_ starred: Bool, id: String, accountID: String) async throws
    @concurrent func trashMessage(id: String, accountID: String) async throws
    @concurrent func archiveMessage(id: String, accountID: String) async throws
    @concurrent func markAsUnread(id: String, accountID: String) async throws
    @concurrent func untrashMessage(id: String, accountID: String) async throws
    @concurrent func deleteMessagePermanently(id: String, accountID: String) async throws
    @concurrent func spamMessage(id: String, accountID: String) async throws
    @discardableResult
    @concurrent func modifyLabels(id: String, add: [String], remove: [String], accountID: String) async throws -> GmailMessage
    @concurrent func getThread(id: String, accountID: String) async throws -> GmailThread
    @concurrent func getAttachment(messageID: String, attachmentID: String, accountID: String) async throws -> Data
    @concurrent func emptyTrash(accountID: String) async throws
    @concurrent func emptySpam(accountID: String) async throws
}

// MARK: - GmailMessageService conformance

extension GmailMessageService: MessageFetching {}
