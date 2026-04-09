import Foundation

/// Fetches drafts from the Gmail Drafts API for display in the Drafts folder.
@MainActor
final class GmailDraftService {
    static let shared = GmailDraftService()
    private init() {}

    private let client = GmailAPIClient.shared

    /// Field masks for draft formats, avoiding repetition across getDraft/getDrafts.
    private enum DraftFields {
        static func fields(for format: String) -> String? {
            switch format {
            case "metadata": "id,message(id,threadId,labelIds,snippet,payload/headers,internalDate)"
            case "full": "id,message(id,threadId,labelIds,snippet,payload,internalDate)"
            default: nil
            }
        }
    }

    nonisolated private func appendPageToken(_ token: String?, to path: inout String) {
        guard let token else { return }
        path += "&pageToken=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)"
    }

    // MARK: - List Drafts

    /// Lists draft refs for the authenticated user.
    @concurrent func listDrafts(
        accountID: String,
        pageToken: String? = nil,
        maxResults: Int = 50
    ) async throws(GoogleAPIError) -> GmailDraftListResponse {
        var path = "/users/me/drafts?maxResults=\(maxResults)"
        appendPageToken(pageToken, to: &path)
        return try await client.request(
            path: path,
            fields: "drafts(id,message(id,threadId)),nextPageToken,resultSizeEstimate",
            accountID: accountID
        )
    }

    // MARK: - Get Draft

    /// Fetches a single draft with its full message payload.
    @concurrent func getDraft(id: String, accountID: String, format: String = "metadata") async throws(GoogleAPIError) -> GmailDraft {
        return try await client.request(
            path: "/users/me/drafts/\(id)?format=\(format)",
            fields: DraftFields.fields(for: format),
            accountID: accountID
        )
    }

    // MARK: - Send Draft

    /// Sends an existing draft immediately via the Gmail Drafts/send endpoint.
    @concurrent func sendDraft(draftId: String, accountID: String) async throws(GoogleAPIError) {
        struct SendDraftRequest: Encodable { let id: String }
        let body: Data
        do {
            body = try JSONEncoder().encode(SendDraftRequest(id: draftId))
        } catch {
            throw .encodingError(error)
        }
        let _: GmailMessage = try await GmailAPIClient.shared.request(
            path: "/users/me/drafts/send",
            method: "POST",
            body: body,
            contentType: "application/json",
            fields: "id",
            accountID: accountID
        )
    }

    // MARK: - Draft mutations

    @concurrent func createDraft(
        from: String, to: [String], cc: [String] = [], bcc: [String] = [],
        subject: String, body: String, isHTML: Bool = false,
        inReplyTo: String? = nil,
        references: String? = nil,
        inlineImages: [InlineImageAttachment] = [],
        threadID: String? = nil,
        accountID: String
    ) async throws(GoogleAPIError) -> GmailDraft {
        try await saveDraft(
            draftID: nil, from: from, to: to, cc: cc, bcc: bcc,
            subject: subject, body: body, isHTML: isHTML,
            inReplyTo: inReplyTo, references: references,
            inlineImages: inlineImages, threadID: threadID, accountID: accountID
        )
    }

    @concurrent func updateDraft(
        draftID: String, from: String, to: [String], cc: [String] = [], bcc: [String] = [],
        subject: String, body: String, isHTML: Bool = false,
        inReplyTo: String? = nil,
        references: String? = nil,
        inlineImages: [InlineImageAttachment] = [],
        threadID: String? = nil,
        accountID: String
    ) async throws(GoogleAPIError) -> GmailDraft {
        try await saveDraft(
            draftID: draftID, from: from, to: to, cc: cc, bcc: bcc,
            subject: subject, body: body, isHTML: isHTML,
            inReplyTo: inReplyTo, references: references,
            inlineImages: inlineImages, threadID: threadID, accountID: accountID
        )
    }

    /// Shared implementation for create (POST) and update (PUT) draft operations.
    @concurrent private func saveDraft(
        draftID: String?, from: String, to: [String], cc: [String], bcc: [String],
        subject: String, body: String, isHTML: Bool,
        inReplyTo: String?,
        references: String?,
        inlineImages: [InlineImageAttachment],
        threadID: String?,
        accountID: String
    ) async throws(GoogleAPIError) -> GmailDraft {
        let raw = try GmailSendService.buildRawMessage(
            from: from, to: to, cc: cc, bcc: bcc,
            subject: subject, body: body, isHTML: isHTML,
            inReplyTo: inReplyTo,
            references: references,
            inlineImages: inlineImages
        )
        var message: [String: Any] = ["raw": raw]
        if let threadID { message["threadId"] = threadID }
        let payload: [String: Any] = ["message": message]
        let encoded: Data
        do {
            encoded = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw .encodingError(error)
        }
        let path = if let draftID { "/users/me/drafts/\(draftID)" } else { "/users/me/drafts" }
        let method = if draftID != nil { "PUT" } else { "POST" }
        return try await client.request(
            path: path,
            method: method, body: encoded, contentType: "application/json",
            fields: "id,message(id,threadId)",
            accountID: accountID
        )
    }

    @concurrent func deleteDraft(draftID: String, accountID: String) async throws(GoogleAPIError) {
        _ = try await client.rawRequest(
            path: "/users/me/drafts/\(draftID)",
            method: "DELETE",
            accountID: accountID
        )
    }

    // MARK: - Batch fetch

    /// Fetches a batch of drafts using Gmail's batch API (up to 50 per request).
    /// Returns successfully fetched drafts and IDs that failed (non-2xx or decode error).
    /// Callers should retry failed IDs on a subsequent sync cycle.
    @concurrent func getDrafts(ids: [String], accountID: String, format: String = "metadata") async throws(GoogleAPIError) -> (drafts: [GmailDraft], failedIDs: [String]) {
        let fieldsParam = DraftFields.fields(for: format)
            .map { "&fields=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" } ?? ""
        let result: BatchFetchResult<GmailDraft> = try await client.batchFetch(
            ids: ids,
            pathBuilder: { "/gmail/v1/users/me/drafts/\($0)?format=\(format)\(fieldsParam)" },
            accountID: accountID
        )
        let sorted = result.items.sorted {
            ($0.message?.date ?? .distantPast) > ($1.message?.date ?? .distantPast)
        }
        return (drafts: sorted, failedIDs: result.failedIDs)
    }
}
