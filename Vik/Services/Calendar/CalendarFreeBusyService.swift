import Foundation
private import os

// MARK: - CalendarFreeBusyService

@MainActor
final class CalendarFreeBusyService {
    static let shared = CalendarFreeBusyService()
    private let client = CalendarAPIClient.shared
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "CalendarFreeBusyService")
    private init() {}

    // MARK: - Free/Busy Query

    /// Queries free/busy information for the given calendar IDs over the specified time range.
    @concurrent func queryFreeBusy(
        calendars: [String],
        timeMin: Date,
        timeMax: Date,
        accountID: String
    ) async throws(CalendarAPIError) -> CalendarAPIFreeBusyResponse {
        let formatter = ISO8601DateFormatter()
        let requestBody = CalendarAPIFreeBusyRequest(
            timeMin: formatter.string(from: timeMin),
            timeMax: formatter.string(from: timeMax),
            timeZone: TimeZone.current.identifier,
            items: calendars.map { CalendarAPIFreeBusyRequestItem(id: $0) }
        )
        let body: Data
        do {
            body = try JSONEncoder().encode(requestBody)
        } catch {
            throw .encodingError(error)
        }
        let response: CalendarAPIFreeBusyResponse = try await client.request(
            path: "/freeBusy",
            method: "POST",
            body: body,
            accountID: accountID
        )
        Self.logger.debug("queryFreeBusy: queried \(calendars.count) calendars for account \(accountID)")
        return response
    }
}
