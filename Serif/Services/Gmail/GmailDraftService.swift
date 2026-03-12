import Foundation

/// Fetches drafts from the Gmail Drafts API for display in the Drafts folder.
@MainActor
final class GmailDraftService {
    static let shared = GmailDraftService()
    private init() {}

    private let client = GmailAPIClient.shared

    // MARK: - List Drafts

    /// Lists draft refs for the authenticated user.
    @concurrent func listDrafts(
        accountID: String,
        pageToken: String? = nil,
        maxResults: Int = 50
    ) async throws(GmailAPIError) -> GmailDraftListResponse {
        var path = "/users/me/drafts?maxResults=\(maxResults)"
        if let token = pageToken { path += "&pageToken=\(token)" }
        return try await client.request(
            path: path,
            fields: "drafts(id,message(id,threadId)),nextPageToken,resultSizeEstimate",
            accountID: accountID
        )
    }

    // MARK: - Get Draft

    /// Fetches a single draft with its full message payload.
    @concurrent func getDraft(id: String, accountID: String, format: String = "metadata") async throws(GmailAPIError) -> GmailDraft {
        let draftFields: String? = switch format {
        case "metadata": "id,message(id,threadId,labelIds,snippet,payload/headers,internalDate)"
        case "full": "id,message(id,threadId,labelIds,snippet,payload,internalDate)"
        default: nil
        }
        return try await client.request(
            path: "/users/me/drafts/\(id)?format=\(format)",
            fields: draftFields,
            accountID: accountID
        )
    }

    // MARK: - Send Draft

    /// Sends an existing draft immediately via the Gmail Drafts/send endpoint.
    @concurrent func sendDraft(draftId: String, accountID: String) async throws(GmailAPIError) {
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
            accountID: accountID
        )
    }

    // MARK: - Batch fetch

    /// Fetches a batch of drafts using Gmail's batch API (up to 50 per request).
    @concurrent func getDrafts(ids: [String], accountID: String, format: String = "metadata") async throws(GmailAPIError) -> [GmailDraft] {
        let drafts: [GmailDraft] = try await client.batchFetch(
            ids: ids,
            pathBuilder: { "/gmail/v1/users/me/drafts/\($0)?format=\(format)" },
            accountID: accountID
        )
        return drafts.sorted {
            ($0.message?.date ?? .distantPast) > ($1.message?.date ?? .distantPast)
        }
    }
}
