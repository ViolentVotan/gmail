import Foundation

@MainActor
final class GmailLabelService {
    static let shared = GmailLabelService()
    private init() {}

    @concurrent func listLabels(accountID: String) async throws(GmailAPIError) -> [GmailLabel] {
        let response: GmailLabelListResponse = try await GmailAPIClient.shared.request(
            path: "/users/me/labels",
            fields: "labels(id,name,type,messagesTotal,messagesUnread,threadsTotal,threadsUnread,color,labelListVisibility,messageListVisibility)",
            accountID: accountID
        )
        return response.labels
    }

    @concurrent func getLabel(id: String, accountID: String) async throws(GmailAPIError) -> GmailLabel {
        return try await GmailAPIClient.shared.request(
            path: "/users/me/labels/\(id)",
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
        return try await GmailAPIClient.shared.request(
            path: "/users/me/labels/\(id)",
            method: "PATCH", body: body, contentType: "application/json",
            accountID: accountID
        )
    }

    @concurrent func deleteLabel(id: String, accountID: String) async throws(GmailAPIError) {
        _ = try await GmailAPIClient.shared.rawRequest(
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
        return try await GmailAPIClient.shared.request(
            path: "/users/me/labels",
            method: "POST", body: body, contentType: "application/json",
            accountID: accountID
        )
    }
}
