import Foundation

struct GmailFilter: Codable, Identifiable, Sendable {
    let id: String
    let criteria: FilterCriteria?
    let action: FilterAction?

    struct FilterCriteria: Codable, Sendable {
        var from: String?
        var to: String?
        var subject: String?
        var query: String?
        var negatedQuery: String?
        var hasAttachment: Bool?
        var excludeChats: Bool?
        var size: Int?
        var sizeComparison: String?
    }

    struct FilterAction: Codable, Sendable {
        var addLabelIds: [String]?
        var removeLabelIds: [String]?
        var forward: String?
    }
}

struct GmailFilterListResponse: Codable, Sendable {
    let filter: [GmailFilter]?
}

@MainActor
final class GmailFilterService {
    static let shared = GmailFilterService()
    private init() {}
    private let client = GmailAPIClient.shared

    func listFilters(accountID: String) async throws(GmailAPIError) -> [GmailFilter] {
        let response: GmailFilterListResponse = try await client.request(path: "/users/me/settings/filters", accountID: accountID)
        return response.filter ?? []
    }

    func createFilter(criteria: GmailFilter.FilterCriteria, action: GmailFilter.FilterAction, accountID: String) async throws(GmailAPIError) -> GmailFilter {
        struct CreateRequest: Encodable {
            let criteria: GmailFilter.FilterCriteria
            let action: GmailFilter.FilterAction
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(CreateRequest(criteria: criteria, action: action))
        } catch {
            throw .encodingError(error)
        }
        return try await client.request(path: "/users/me/settings/filters", method: "POST", body: body, contentType: "application/json", accountID: accountID)
    }

    func deleteFilter(id: String, accountID: String) async throws(GmailAPIError) {
        _ = try await client.rawRequest(path: "/users/me/settings/filters/\(id)", method: "DELETE", accountID: accountID)
    }
}
