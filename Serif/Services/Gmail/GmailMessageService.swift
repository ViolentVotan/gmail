import Foundation

@MainActor
final class GmailMessageService {
    static let shared = GmailMessageService()
    private init() {}

    private let client = GmailAPIClient.shared

    // MARK: - List

    /// Lists message refs for a given label and optional search query.
    @concurrent func listMessages(
        accountID: String,
        labelIDs: [String] = [GmailSystemLabel.inbox],
        query: String? = nil,
        pageToken: String? = nil,
        maxResults: Int = 50
    ) async throws(GmailAPIError) -> GmailMessageListResponse {
        var path = "/users/me/messages?maxResults=\(maxResults)"
        for label in labelIDs { path += GmailPathBuilder.labelQueryParam(label) }
        if let q = query, !q.isEmpty {
            path += "&q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)"
        }
        if let token = pageToken { path += "&pageToken=\(token)" }
        return try await client.request(
            path: path,
            fields: "messages(id,threadId),nextPageToken,resultSizeEstimate",
            accountID: accountID
        )
    }

    // MARK: - Fetch single message

    /// Fetches a single message. Use format "full" for detail view, "metadata" for list.
    @concurrent func getMessage(id: String, accountID: String, format: String = "full") async throws(GmailAPIError) -> GmailMessage {
        let messageFields: String? = switch format {
        case "metadata": "id,threadId,labelIds,snippet,payload/headers,internalDate,sizeEstimate"
        case "full": "id,threadId,labelIds,snippet,payload,internalDate"
        default: nil
        }
        return try await client.request(
            path: "/users/me/messages/\(id)?format=\(format)",
            fields: messageFields,
            accountID: accountID
        )
    }

    /// Fetches the raw RFC 2822 source of a message.
    @concurrent func getRawMessage(id: String, accountID: String) async throws(GmailAPIError) -> GmailMessage {
        try await getMessage(id: id, accountID: accountID, format: "raw")
    }

    /// Fetches a batch of messages using Gmail's batch API (up to 50 per request).
    @concurrent func getMessages(ids: [String], accountID: String, format: String = "metadata") async throws(GmailAPIError) -> [GmailMessage] {
        let messages: [GmailMessage] = try await client.batchFetch(
            ids: ids,
            pathBuilder: { "/gmail/v1/users/me/messages/\($0)?format=\(format)" },
            accountID: accountID
        )
        return messages.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: - Threads

    @concurrent func getThread(id: String, accountID: String) async throws(GmailAPIError) -> GmailThread {
        try await client.request(
            path: "/users/me/threads/\(id)?format=full",
            fields: "id,messages(id,threadId,labelIds,snippet,payload,internalDate)",
            accountID: accountID
        )
    }

    // MARK: - History

    /// Fetches history records since the given historyId.
    /// Pass labelId to filter only changes relevant to a specific label.
    @concurrent func listHistory(
        accountID: String,
        startHistoryId: String,
        labelId: String? = nil,
        pageToken: String? = nil,
        maxResults: Int = 500
    ) async throws(GmailAPIError) -> GmailHistoryListResponse {
        var path = "/users/me/history?startHistoryId=\(startHistoryId)&maxResults=\(maxResults)"
        path += "&historyTypes=messageAdded&historyTypes=messageDeleted"
        path += "&historyTypes=labelAdded&historyTypes=labelRemoved"
        if let labelId { path += "&labelId=\(labelId)" }
        if let token = pageToken { path += "&pageToken=\(token)" }
        return try await client.request(
            path: path,
            fields: "history(id,messagesAdded,messagesDeleted,labelsAdded,labelsRemoved),historyId,nextPageToken",
            accountID: accountID
        )
    }

    // MARK: - Mutations

    @concurrent func markAsRead(id: String, accountID: String) async throws(GmailAPIError) {
        try await modifyLabels(id: id, add: [], remove: [GmailSystemLabel.unread], accountID: accountID)
    }

    @concurrent func setStarred(_ starred: Bool, id: String, accountID: String) async throws(GmailAPIError) {
        if starred {
            try await modifyLabels(id: id, add: [GmailSystemLabel.starred], remove: [], accountID: accountID)
        } else {
            try await modifyLabels(id: id, add: [], remove: [GmailSystemLabel.starred], accountID: accountID)
        }
    }

    @discardableResult
    @concurrent func trashMessage(id: String, accountID: String) async throws(GmailAPIError) -> GmailMessage {
        try await client.request(
            path: "/users/me/messages/\(id)/trash",
            method: "POST",
            accountID: accountID
        )
    }

    @concurrent func archiveMessage(id: String, accountID: String) async throws(GmailAPIError) {
        try await modifyLabels(id: id, add: [], remove: [GmailSystemLabel.inbox], accountID: accountID)
    }

    @concurrent func markAsUnread(id: String, accountID: String) async throws(GmailAPIError) {
        try await modifyLabels(id: id, add: [GmailSystemLabel.unread], remove: [], accountID: accountID)
    }

    @discardableResult
    @concurrent func untrashMessage(id: String, accountID: String) async throws(GmailAPIError) -> GmailMessage {
        try await client.request(
            path: "/users/me/messages/\(id)/untrash",
            method: "POST",
            accountID: accountID
        )
    }

    @concurrent func deleteMessagePermanently(id: String, accountID: String) async throws(GmailAPIError) {
        _ = try await client.rawRequest(
            path: "/users/me/messages/\(id)",
            method: "DELETE",
            accountID: accountID
        )
    }

    @concurrent func spamMessage(id: String, accountID: String) async throws(GmailAPIError) {
        try await modifyLabels(id: id, add: [GmailSystemLabel.spam], remove: [GmailSystemLabel.inbox], accountID: accountID)
    }

    @discardableResult
    @concurrent func modifyLabels(id: String, add: [String], remove: [String], accountID: String) async throws(GmailAPIError) -> GmailMessage {
        struct ModifyRequest: Encodable { let addLabelIds: [String]; let removeLabelIds: [String] }
        let body: Data
        do {
            body = try JSONEncoder().encode(ModifyRequest(addLabelIds: add, removeLabelIds: remove))
        } catch {
            throw .encodingError(error)
        }
        return try await client.request(
            path: "/users/me/messages/\(id)/modify",
            method: "POST", body: body, contentType: "application/json",
            accountID: accountID
        )
    }

    /// Permanently deletes all messages in Trash.
    /// Continues through all batches even if some fail, then reports partial failure.
    @concurrent func emptyTrash(accountID: String) async throws(GmailAPIError) {
        try await emptyFolder(labelID: GmailSystemLabel.trash, accountID: accountID)
    }

    /// Permanently deletes all messages in Spam.
    /// Continues through all batches even if some fail, then reports partial failure.
    @concurrent func emptySpam(accountID: String) async throws(GmailAPIError) {
        try await emptyFolder(labelID: GmailSystemLabel.spam, accountID: accountID)
    }

    @concurrent private func emptyFolder(labelID: String, accountID: String) async throws(GmailAPIError) {
        var pageToken: String? = nil
        var allIDs: [String] = []
        repeat {
            let response = try await listMessages(
                accountID: accountID,
                labelIDs: [labelID],
                pageToken: pageToken,
                maxResults: 100
            )
            allIDs.append(contentsOf: response.messages?.map(\.id) ?? [])
            pageToken = response.nextPageToken
        } while pageToken != nil

        guard !allIDs.isEmpty else { return }

        // Batch delete in groups of 1000 (API limit), accumulating failures
        var failedIDs: [String] = []
        for batch in stride(from: 0, to: allIDs.count, by: 1000) {
            let ids = Array(allIDs[batch..<min(batch + 1000, allIDs.count)])
            do {
                struct BatchDeleteRequest: Encodable { let ids: [String] }
                let body = try JSONEncoder().encode(BatchDeleteRequest(ids: ids))
                _ = try await client.rawRequest(
                    path: "/users/me/messages/batchDelete",
                    method: "POST", body: body, contentType: "application/json",
                    accountID: accountID
                )
            } catch {
                failedIDs.append(contentsOf: ids)
            }
        }
        if !failedIDs.isEmpty {
            throw .partialFailure(failedCount: failedIDs.count)
        }
    }

    // MARK: - Attachments

    /// Downloads raw attachment data by attachment ID.
    @concurrent func getAttachment(messageID: String, attachmentID: String, accountID: String) async throws(GmailAPIError) -> Data {
        let response: GmailAttachmentResponse = try await client.request(
            path: "/users/me/messages/\(messageID)/attachments/\(attachmentID)",
            accountID: accountID
        )
        guard let data = Data(base64URLEncoded: response.data) else {
            throw .decodingError(URLError(.badServerResponse))
        }
        return data
    }
}
