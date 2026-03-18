import Foundation
private import os

// MARK: - CalendarListService

@MainActor
final class CalendarListService {
    static let shared = CalendarListService()
    private let client = CalendarAPIClient.shared
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "CalendarListService")
    private init() {}

    // MARK: - Calendar List

    /// Lists all calendars for the given account, paginating through all results.
    @concurrent func listCalendars(
        accountID: String
    ) async throws(CalendarAPIError) -> [CalendarAPICalendarListEntry] {
        var all: [CalendarAPICalendarListEntry] = []
        var pageToken: String? = nil

        repeat {
            var queryItems: [URLQueryItem] = [URLQueryItem(name: "maxResults", value: "250")]
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
        } while pageToken != nil

        Self.logger.debug("listCalendars: fetched \(all.count) calendars for account \(accountID)")
        return all
    }

    /// Performs an incremental sync of the calendar list using a sync token.
    /// Returns only calendars changed since the previous sync.
    @concurrent func syncCalendars(
        accountID: String,
        syncToken: String
    ) async throws(CalendarAPIError) -> CalendarListSyncResponse {
        let queryItems = [URLQueryItem(name: "syncToken", value: syncToken)]
        let response: CalendarListSyncResponse = try await client.request(
            path: "/users/me/calendarList",
            queryItems: queryItems,
            accountID: accountID
        )
        Self.logger.debug("syncCalendars: received \(response.items?.count ?? 0) changed calendars for account \(accountID)")
        return response
    }

    // MARK: - Colors

    /// Fetches the color palette for calendar and event colors.
    @concurrent func getColors(
        accountID: String
    ) async throws(CalendarAPIError) -> CalendarAPIColors {
        let colors: CalendarAPIColors = try await client.request(
            path: "/colors",
            accountID: accountID
        )
        return colors
    }

    // MARK: - Settings

    /// Fetches all user settings (e.g., timezone), paginating through all results.
    @concurrent func getSettings(
        accountID: String
    ) async throws(CalendarAPIError) -> [CalendarAPISetting] {
        var all: [CalendarAPISetting] = []
        var pageToken: String? = nil

        repeat {
            var queryItems: [URLQueryItem] = []
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let response: CalendarAPISettingsListResponse = try await client.request(
                path: "/users/me/settings",
                queryItems: queryItems.isEmpty ? nil : queryItems,
                accountID: accountID
            )
            all.append(contentsOf: response.items ?? [])
            pageToken = response.nextPageToken
        } while pageToken != nil

        Self.logger.debug("getSettings: fetched \(all.count) settings for account \(accountID)")
        return all
    }
}
