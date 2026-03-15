import Foundation

@MainActor
final class GmailLabelService {
    static let shared = GmailLabelService()
    private let client = GmailAPIClient.shared
    private init() {}

    @concurrent func listLabels(accountID: String) async throws(GmailAPIError) -> [GmailLabel] {
        let response: GmailLabelListResponse = try await client.request(
            path: "/users/me/labels",
            fields: "labels(id,name,type,messagesTotal,messagesUnread,threadsTotal,threadsUnread,color,labelListVisibility,messageListVisibility)",
            accountID: accountID
        )
        return response.labels
    }

    /// Fetches labels with ETag-based cache validation.
    /// Returns `nil` if the server responds 304 Not Modified (labels unchanged).
    /// Returns `(labels, etag)` on a fresh 200 response.
    @concurrent func listLabels(etag: String?, accountID: String) async throws(GmailAPIError) -> ([GmailLabel], String?)? {
        let result: (GmailLabelListResponse, String?)? = try await client.requestWithETag(
            path: "/users/me/labels",
            etag: etag,
            fields: "labels(id,name,type,messagesTotal,messagesUnread,threadsTotal,threadsUnread,color,labelListVisibility,messageListVisibility)",
            accountID: accountID
        )
        guard let (response, responseETag) = result else { return nil }
        return (response.labels, responseETag)
    }

    @concurrent func getLabel(id: String, accountID: String) async throws(GmailAPIError) -> GmailLabel {
        return try await client.request(
            path: "/users/me/labels/\(id)",
            fields: "id,name,type,messagesTotal,messagesUnread,threadsTotal,threadsUnread,color",
            accountID: accountID
        )
    }

    @concurrent func updateLabel(id: String, newName: String, accountID: String) async throws(GmailAPIError) -> GmailLabel {
        struct UpdateRequest: Encodable { let name: String }
        let body: Data
        do {
            body = try JSONEncoder().encode(UpdateRequest(name: newName))
        } catch {
            throw .encodingError(error)
        }
        return try await client.request(
            path: "/users/me/labels/\(id)",
            method: "PATCH", body: body, contentType: "application/json",
            accountID: accountID
        )
    }

    @concurrent func deleteLabel(id: String, accountID: String) async throws(GmailAPIError) {
        _ = try await client.rawRequest(
            path: "/users/me/labels/\(id)",
            method: "DELETE",
            accountID: accountID
        )
    }

    @concurrent func createLabel(name: String, accountID: String) async throws(GmailAPIError) -> GmailLabel {
        struct CreateRequest: Encodable {
            let name: String
            let labelListVisibility: String
            let messageListVisibility: String
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(
                CreateRequest(name: name, labelListVisibility: "labelShow", messageListVisibility: "show")
            )
        } catch {
            throw .encodingError(error)
        }
        return try await client.request(
            path: "/users/me/labels",
            method: "POST", body: body, contentType: "application/json",
            accountID: accountID
        )
    }
}
