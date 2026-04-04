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
    ) async throws(GoogleAPIError) -> (entries: [CalendarAPICalendarListEntry], syncToken: String?) {
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

        Self.logger.debug("listCalendars: fetched \(all.count) calendars for account \(accountID, privacy: .private)")
        return (entries: all, syncToken: lastSyncToken)
    }

    /// Performs an incremental sync of the calendar list using a sync token, paginating all results.
    /// Returns all calendars changed since the previous sync and the new sync token.
    @concurrent func syncCalendars(
        accountID: String,
        syncToken: String
    ) async throws(GoogleAPIError) -> (entries: [CalendarAPICalendarListEntry], syncToken: String?) {
        var allEntries: [CalendarAPICalendarListEntry] = []
        var pageToken: String? = nil
        var latestSyncToken: String? = nil

        repeat {
            var queryItems = [
                URLQueryItem(name: "syncToken", value: syncToken),
                URLQueryItem(name: "fields", value: Self.calendarListFieldMask),
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let response: CalendarListSyncResponse = try await client.request(
                path: "/users/me/calendarList",
                queryItems: queryItems,
                accountID: accountID
            )
            allEntries.append(contentsOf: response.items ?? [])
            latestSyncToken = response.nextSyncToken ?? latestSyncToken
            pageToken = response.nextPageToken
        } while pageToken != nil

        Self.logger.debug("syncCalendars: received \(allEntries.count) changed calendars for account \(accountID, privacy: .private)")
        return (entries: allEntries, syncToken: latestSyncToken)
    }

}
