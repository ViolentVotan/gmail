import Foundation
@testable import Serif

/// Minimal mock for `MessageFetching` that returns empty responses.
/// Used by `FullSyncEngineTests` and other tests that need a non-network API layer.
@MainActor
final class MockMessageFetching: MessageFetching {
    // MARK: - Configurable responses (nonisolated for @concurrent method access in tests)

    nonisolated(unsafe) var listMessagesResponse = GmailMessageListResponse(messages: nil, nextPageToken: nil, resultSizeEstimate: 0)
    nonisolated(unsafe) var getMessageResponse: GmailMessage?
    nonisolated(unsafe) var getMessagesResponse: [GmailMessage] = []
    nonisolated(unsafe) var listHistoryResponse = GmailHistoryListResponse(history: nil, nextPageToken: nil, historyId: "1")

    // MARK: - MessageFetching

    @concurrent func listMessages(accountID: String, labelIDs: [String], query: String?, pageToken: String?, maxResults: Int) async throws(GmailAPIError) -> GmailMessageListResponse {
        listMessagesResponse
    }

    @concurrent func getMessage(id: String, accountID: String, format: String) async throws(GmailAPIError) -> GmailMessage {
        guard let msg = getMessageResponse else {
            throw .httpError(404, Data())
        }
        return msg
    }

    @concurrent func getMessages(ids: [String], accountID: String, format: String) async throws(GmailAPIError) -> [GmailMessage] {
        getMessagesResponse
    }

    @concurrent func listHistory(accountID: String, startHistoryId: String, labelId: String?, pageToken: String?, maxResults: Int) async throws(GmailAPIError) -> GmailHistoryListResponse {
        listHistoryResponse
    }

    @concurrent func markAsRead(id: String, accountID: String) async throws(GmailAPIError) {}
    @concurrent func setStarred(_ starred: Bool, id: String, accountID: String) async throws(GmailAPIError) {}
    @concurrent func trashMessage(id: String, accountID: String) async throws(GmailAPIError) -> GmailMessage {
        throw .httpError(501, Data())
    }
    @concurrent func archiveMessage(id: String, accountID: String) async throws(GmailAPIError) {}
    @concurrent func markAsUnread(id: String, accountID: String) async throws(GmailAPIError) {}
    @concurrent func untrashMessage(id: String, accountID: String) async throws(GmailAPIError) -> GmailMessage {
        throw .httpError(501, Data())
    }
    @concurrent func deleteMessagePermanently(id: String, accountID: String) async throws(GmailAPIError) {}
    @concurrent func spamMessage(id: String, accountID: String) async throws(GmailAPIError) {}
    @concurrent func modifyLabels(id: String, add: [String], remove: [String], accountID: String) async throws(GmailAPIError) -> GmailMessage {
        throw .httpError(501, Data())
    }
    @concurrent func getThread(id: String, accountID: String) async throws(GmailAPIError) -> GmailThread {
        throw .httpError(501, Data())
    }
    @concurrent func getAttachment(messageID: String, attachmentID: String, accountID: String) async throws(GmailAPIError) -> Data {
        Data()
    }
    @concurrent func emptyTrash(accountID: String) async throws(GmailAPIError) {}
    @concurrent func emptySpam(accountID: String) async throws(GmailAPIError) {}
    @concurrent func getProfile(accountID: String) async throws(GmailAPIError) -> GmailProfile {
        GmailProfile(emailAddress: "test@example.com", messagesTotal: 0, threadsTotal: 0, historyId: "12345")
    }
}
