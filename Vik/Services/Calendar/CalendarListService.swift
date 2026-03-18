import Foundation
private import os

// MARK: - CalendarListService

@MainActor
final class CalendarListService {
    static let shared = CalendarListService()
    private let client = CalendarAPIClient.shared
    nonisolated private static let logger = Logger(category: "CalendarListService")
    private init() {}

    // MARK: - Field mask

    nonisolated private static let calendarListFieldMask =
        "items(id,summary,description,timeZone,backgroundColor,foregroundColor,primary,accessRole,hidden,summaryOverride),nextPageToken,nextSyncToken"

    // MARK: - Calendar List

    /// Lists all calendars for the given account, paginating through all results.
    @concurrent func listCalendars(
        accountID: String
    ) async throws(CalendarAPIError) -> (entries: [CalendarAPICalendarListEntry], syncToken: String?) {
        var all: [CalendarAPICalendarListEntry] = []
        var pageToken: String? = nil
        var lastSyncToken: String? = nil

        repeat {
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "fields", value: Self.calendarListFieldMask),
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let response: CalendarAPICalendarListResponse = try await client.request(
                path: "/users/me/calendarList",
                queryItems: queryItems,
                accountID: accountID
            )
            all.append(contentsOf: response.items ?? [])
            pageToken = response.nextPageToken
            lastSyncToken = response.nextSyncToken
        } while pageToken != nil

        Self.logger.debug("listCalendars: fetched \(all.count) calendars for account \(accountID)")
        return (entries: all, syncToken: lastSyncToken)
    }

    /// Performs an incremental sync of the calendar list using a sync token.
    /// Returns only calendars changed since the previous sync.
    @concurrent func syncCalendars(
        accountID: String,
        syncToken: String
    ) async throws(CalendarAPIError) -> CalendarListSyncResponse {
        let queryItems = [
            URLQueryItem(name: "syncToken", value: syncToken),
            URLQueryItem(name: "fields", value: Self.calendarListFieldMask),
        ]
        let response: CalendarListSyncResponse = try await client.request(
            path: "/users/me/calendarList",
            queryItems: queryItems,
            accountID: accountID
        )
        Self.logger.debug("syncCalendars: received \(response.items?.count ?? 0) changed calendars for account \(accountID)")
        return response
    }

}
