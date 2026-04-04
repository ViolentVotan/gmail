import Foundation
@testable import Vik

/// Minimal mock for `MessageFetching` that returns empty responses.
/// Used by `FullSyncEngineTests` and other tests that need a non-network API layer.
@MainActor
final class MockMessageFetching: MessageReading, MessageMutating, AttachmentFetching, MailboxManaging {
    // MARK: - Configurable responses (nonisolated for @concurrent method access in tests)

    nonisolated(unsafe) var listMessagesResponse = GmailMessageListResponse(messages: nil, nextPageToken: nil, resultSizeEstimate: 0)
    nonisolated(unsafe) var getMessageResponse: GmailMessage?
    nonisolated(unsafe) var getMessagesResponse: [GmailMessage] = []
    nonisolated(unsafe) var listHistoryResponse = GmailHistoryListResponse(history: nil, nextPageToken: nil, historyId: "1")

    // MARK: - MessageReading / MessageMutating / AttachmentFetching / MailboxManaging

    @concurrent func listMessages(accountID: String, labelIDs: [String], query: String?, pageToken: String?, maxResults: Int) async throws(GoogleAPIError) -> GmailMessageListResponse {
        listMessagesResponse
    }

    @concurrent func getMessage(id: String, accountID: String, format: String) async throws(GoogleAPIError) -> GmailMessage {
        guard let msg = getMessageResponse else {
            throw .httpError(404, Data())
        }
        return msg
    }

    @concurrent func getMessages(ids: [String], accountID: String, format: String) async throws(GoogleAPIError) -> (messages: [GmailMessage], failedIDs: [String]) {
        (messages: getMessagesResponse, failedIDs: [])
    }

    @concurrent func listHistory(accountID: String, startHistoryId: String, labelId: String?, pageToken: String?, maxResults: Int) async throws(GoogleAPIError) -> GmailHistoryListResponse {
        listHistoryResponse
    }

    @concurrent func markAsRead(id: String, accountID: String) async throws(GoogleAPIError) {}
    @concurrent func setStarred(_ starred: Bool, id: String, accountID: String) async throws(GoogleAPIError) {}
    @concurrent func trashMessage(id: String, accountID: String) async throws(GoogleAPIError) -> GmailMessage {
        throw .httpError(501, Data())
    }
    @concurrent func archiveMessage(id: String, accountID: String) async throws(GoogleAPIError) {}
    @concurrent func markAsUnread(id: String, accountID: String) async throws(GoogleAPIError) {}
    @concurrent func untrashMessage(id: String, accountID: String) async throws(GoogleAPIError) -> GmailMessage {
        throw .httpError(501, Data())
    }
    @concurrent func deleteMessagePermanently(id: String, accountID: String) async throws(GoogleAPIError) {}
    @concurrent func spamMessage(id: String, accountID: String) async throws(GoogleAPIError) {}
    @concurrent func modifyLabels(id: String, add: [String], remove: [String], accountID: String) async throws(GoogleAPIError) -> GmailMessage {
        throw .httpError(501, Data())
    }
    @concurrent func getThread(id: String, accountID: String) async throws(GoogleAPIError) -> GmailThread {
        throw .httpError(501, Data())
    }
    @concurrent func getAttachment(messageID: String, attachmentID: String, accountID: String) async throws(GoogleAPIError) -> Data {
        Data()
    }
    @concurrent func batchModifyLabels(ids: [String], add addLabelIds: [String], remove removeLabelIds: [String], accountID: String) async throws(GoogleAPIError) {}
    @concurrent func emptyTrash(accountID: String) async throws(GoogleAPIError) {}
    @concurrent func emptySpam(accountID: String) async throws(GoogleAPIError) {}
    @concurrent func getProfile(accountID: String) async throws(GoogleAPIError) -> GmailProfile {
        GmailProfile(emailAddress: "test@example.com", messagesTotal: 0, threadsTotal: 0, historyId: "12345")
    }
}
