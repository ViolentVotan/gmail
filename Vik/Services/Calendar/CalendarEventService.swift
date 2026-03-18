import Foundation
private import os

@MainActor
final class CalendarEventService {
    static let shared = CalendarEventService()
    private let client = CalendarAPIClient.shared
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "CalendarEventService")
    private init() {}

    // MARK: - Date formatting

    /// Formats a Date as RFC3339 with fractional seconds, safe for use from any isolation context.
    nonisolated static func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Percent-encodes a calendar or event ID for safe interpolation into a URL path segment.
    /// Calendar IDs for shared/secondary calendars may contain `#`, which would truncate the URL
    /// at the fragment boundary if not encoded.
    nonisolated private static func encodePath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    // MARK: - Field mask

    nonisolated private static let eventFieldMask =
        "items(id,status,htmlLink,created,updated,summary,description,location,colorId,creator,organizer,start,end,recurrence,recurringEventId,transparency,visibility,iCalUID,sequence,attendees,conferenceData,reminders,attachments,eventType,etag,hangoutLink,guestsCanModify,extendedProperties),nextPageToken,nextSyncToken"

    // MARK: - List

    /// Lists events in a calendar for the given date range, expanding recurring instances.
    /// Pass `pageToken` to fetch subsequent pages of a paginated response.
    @concurrent func listEvents(
        calendarId: String,
        accountID: String,
        timeMin: Date,
        timeMax: Date,
        singleEvents: Bool = true,
        maxResults: Int = 250,
        pageToken: String? = nil
    ) async throws(CalendarAPIError) -> CalendarEventListResponse {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "timeMin", value: Self.rfc3339(timeMin)),
            URLQueryItem(name: "timeMax", value: Self.rfc3339(timeMax)),
            URLQueryItem(name: "singleEvents", value: singleEvents ? "true" : "false"),
            URLQueryItem(name: "maxResults", value: "\(maxResults)"),
            URLQueryItem(name: "fields", value: Self.eventFieldMask),
        ]
        if singleEvents {
            queryItems.append(URLQueryItem(name: "orderBy", value: "startTime"))
        }
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        return try await client.request(
            path: "/calendars/\(Self.encodePath(calendarId))/events",
            queryItems: queryItems,
            accountID: accountID
        )
    }

    /// Incremental sync using a syncToken from a previous response.
    /// Returns deleted events as items with status "cancelled".
    @concurrent func syncEvents(
        calendarId: String,
        accountID: String,
        syncToken: String,
        pageToken: String? = nil
    ) async throws(CalendarAPIError) -> CalendarEventListResponse {
        var queryItems = [
            URLQueryItem(name: "syncToken", value: syncToken),
            URLQueryItem(name: "fields", value: Self.eventFieldMask),
        ]
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        return try await client.request(
            path: "/calendars/\(Self.encodePath(calendarId))/events",
            queryItems: queryItems,
            accountID: accountID
        )
    }

    // MARK: - Fetch single event

    /// Fetches a single event by ID.
    @concurrent func getEvent(
        calendarId: String,
        eventId: String,
        accountID: String
    ) async throws(CalendarAPIError) -> CalendarAPIEvent {
        try await client.request(
            path: "/calendars/\(Self.encodePath(calendarId))/events/\(Self.encodePath(eventId))",
            accountID: accountID
        )
    }

    // MARK: - Create

    /// Creates a new event in the specified calendar.
    @concurrent func insertEvent(
        calendarId: String,
        event: CalendarAPIEventInput,
        accountID: String,
        conferenceDataVersion: Int? = nil
    ) async throws(CalendarAPIError) -> CalendarAPIEvent {
        let body: Data
        do {
            body = try JSONEncoder().encode(event)
        } catch {
            throw .encodingError(error)
        }
        var queryItems: [URLQueryItem] = []
        if let version = conferenceDataVersion {
            queryItems.append(URLQueryItem(name: "conferenceDataVersion", value: "\(version)"))
        }
        return try await client.request(
            path: "/calendars/\(Self.encodePath(calendarId))/events",
            method: "POST",
            body: body,
            queryItems: queryItems.isEmpty ? nil : queryItems,
            accountID: accountID
        )
    }

    // MARK: - Update

    /// Replaces an event (PUT). If an etag is provided, sends `If-Match` for optimistic concurrency.
    @concurrent func updateEvent(
        calendarId: String,
        eventId: String,
        event: CalendarAPIEventInput,
        accountID: String,
        etag: String?
    ) async throws(CalendarAPIError) -> CalendarAPIEvent {
        let body: Data
        do {
            body = try JSONEncoder().encode(event)
        } catch {
            throw .encodingError(error)
        }
        var headers: [String: String]? = nil
        if let etag {
            headers = ["If-Match": etag]
        }
        return try await client.request(
            path: "/calendars/\(Self.encodePath(calendarId))/events/\(Self.encodePath(eventId))",
            method: "PUT",
            body: body,
            extraHeaders: headers,
            accountID: accountID
        )
    }

    // MARK: - Patch (private)

    /// Sends a partial update (PATCH) with raw JSON fields. Used internally by `respondToEvent`.
    private func patchEvent(
        calendarId: String,
        eventId: String,
        fields: Data,
        accountID: String,
        etag: String?
    ) async throws(CalendarAPIError) -> CalendarAPIEvent {
        var headers: [String: String]? = nil
        if let etag {
            headers = ["If-Match": etag]
        }
        return try await client.request(
            path: "/calendars/\(Self.encodePath(calendarId))/events/\(Self.encodePath(eventId))",
            method: "PATCH",
            body: fields,
            extraHeaders: headers,
            accountID: accountID
        )
    }

    // MARK: - Delete

    /// Permanently deletes an event from the calendar.
    @concurrent func deleteEvent(
        calendarId: String,
        eventId: String,
        accountID: String
    ) async throws(CalendarAPIError) {
        try await client.requestVoid(
            path: "/calendars/\(Self.encodePath(calendarId))/events/\(Self.encodePath(eventId))",
            method: "DELETE",
            accountID: accountID
        )
    }

    // MARK: - Quick add

    /// Creates an event from a natural-language text string.
    @concurrent func quickAdd(
        calendarId: String,
        text: String,
        accountID: String
    ) async throws(CalendarAPIError) -> CalendarAPIEvent {
        let queryItems = [URLQueryItem(name: "text", value: text)]
        return try await client.request(
            path: "/calendars/\(Self.encodePath(calendarId))/events/quickAdd",
            method: "POST",
            queryItems: queryItems,
            accountID: accountID
        )
    }

    // MARK: - RSVP

    /// Updates the self attendee's responseStatus for an event.
    /// Fetches the current event to find the self attendee entry, then PATCHes the attendees array.
    @concurrent func respondToEvent(
        calendarId: String,
        eventId: String,
        accountID: String,
        status: String
    ) async throws(CalendarAPIError) -> CalendarAPIEvent {
        let event = try await getEvent(calendarId: calendarId, eventId: eventId, accountID: accountID)

        // Rebuild the attendees list updating only the self attendee's responseStatus.
        struct AttendeeResponsePatch: Encodable {
            let email: String
            let responseStatus: String
        }
        struct AttendeePatch: Encodable {
            let attendees: [AttendeeResponsePatch]
        }

        let updatedAttendees = (event.attendees ?? []).map { attendee -> AttendeeResponsePatch in
            AttendeeResponsePatch(
                email: attendee.email ?? "",
                responseStatus: attendee.isSelf == true ? status : (attendee.responseStatus ?? "needsAction")
            )
        }

        let patch = AttendeePatch(attendees: updatedAttendees)
        let body: Data
        do {
            body = try JSONEncoder().encode(patch)
        } catch {
            throw .encodingError(error)
        }

        return try await patchEvent(
            calendarId: calendarId,
            eventId: eventId,
            fields: body,
            accountID: accountID,
            etag: event.etag
        )
    }

    // MARK: - Move

    /// Moves an event to a different calendar.
    @concurrent func moveEvent(
        calendarId: String,
        eventId: String,
        destinationCalendarId: String,
        accountID: String
    ) async throws(CalendarAPIError) -> CalendarAPIEvent {
        let queryItems = [URLQueryItem(name: "destination", value: destinationCalendarId)]
        return try await client.request(
            path: "/calendars/\(Self.encodePath(calendarId))/events/\(Self.encodePath(eventId))/move",
            method: "POST",
            queryItems: queryItems,
            accountID: accountID
        )
    }
}
