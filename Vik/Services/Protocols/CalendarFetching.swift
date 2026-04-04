import Foundation

// MARK: - CalendarEventReading

/// Read-only access to Google Calendar events.
///
/// Uses `throws(GoogleAPIError)` for typed throws — conforming types can throw
/// `GoogleAPIError` or a subtype (including `Never` for non-throwing mocks).
@MainActor
protocol CalendarEventReading: Sendable {
    @concurrent func listEvents(calendarId: String, accountID: String, timeMin: Date, timeMax: Date, singleEvents: Bool, maxResults: Int, pageToken: String?) async throws(GoogleAPIError) -> CalendarEventListResponse
    @concurrent func syncEvents(calendarId: String, accountID: String, syncToken: String?, pageToken: String?) async throws(GoogleAPIError) -> CalendarEventListResponse
    @concurrent func getEvent(calendarId: String, eventId: String, accountID: String) async throws(GoogleAPIError) -> CalendarAPIEvent
}

// MARK: - CalendarEventMutating

/// Write operations on Google Calendar events (create, update, delete, RSVP, quick-add).
@MainActor
protocol CalendarEventMutating: Sendable {
    @discardableResult
    @concurrent func insertEvent(calendarId: String, event: CalendarAPIEventInput, accountID: String, conferenceDataVersion: Int?, sendUpdates: String?) async throws(GoogleAPIError) -> CalendarAPIEvent
    @discardableResult
    @concurrent func updateEvent(calendarId: String, eventId: String, event: CalendarAPIEventInput, accountID: String, etag: String?, conferenceDataVersion: Int?, sendUpdates: String?) async throws(GoogleAPIError) -> CalendarAPIEvent
    @concurrent func deleteEvent(calendarId: String, eventId: String, accountID: String, sendUpdates: String?) async throws(GoogleAPIError)
    @discardableResult
    @concurrent func respondToEvent(calendarId: String, eventId: String, accountID: String, status: String, sendUpdates: String?) async throws(GoogleAPIError) -> CalendarAPIEvent
    @discardableResult
    @concurrent func quickAdd(calendarId: String, text: String, accountID: String) async throws(GoogleAPIError) -> CalendarAPIEvent
}

// MARK: - CalendarEventMutating defaults

extension CalendarEventMutating {
    @discardableResult
    func insertEvent(calendarId: String, event: CalendarAPIEventInput, accountID: String, conferenceDataVersion: Int? = nil, sendUpdates: String? = "all") async throws(GoogleAPIError) -> CalendarAPIEvent {
        try await insertEvent(calendarId: calendarId, event: event, accountID: accountID, conferenceDataVersion: conferenceDataVersion, sendUpdates: sendUpdates)
    }

    @discardableResult
    func updateEvent(calendarId: String, eventId: String, event: CalendarAPIEventInput, accountID: String, etag: String?, conferenceDataVersion: Int? = nil, sendUpdates: String? = "all") async throws(GoogleAPIError) -> CalendarAPIEvent {
        try await updateEvent(calendarId: calendarId, eventId: eventId, event: event, accountID: accountID, etag: etag, conferenceDataVersion: conferenceDataVersion, sendUpdates: sendUpdates)
    }

    func deleteEvent(calendarId: String, eventId: String, accountID: String, sendUpdates: String? = "all") async throws(GoogleAPIError) {
        try await deleteEvent(calendarId: calendarId, eventId: eventId, accountID: accountID, sendUpdates: sendUpdates)
    }

    @discardableResult
    func respondToEvent(calendarId: String, eventId: String, accountID: String, status: String, sendUpdates: String? = "all") async throws(GoogleAPIError) -> CalendarAPIEvent {
        try await respondToEvent(calendarId: calendarId, eventId: eventId, accountID: accountID, status: status, sendUpdates: sendUpdates)
    }
}

// MARK: - CalendarEventFetching (composition)

/// Full Google Calendar event API surface — backward-compatible alias for protocol composition.
///
/// Callers that only need a subset of operations should narrow their dependency to
/// `CalendarEventReading` or `CalendarEventMutating`.
typealias CalendarEventFetching = CalendarEventReading & CalendarEventMutating

// MARK: - CalendarListReading

/// Read-only access to the user's Google Calendar list.
@MainActor
protocol CalendarListReading: Sendable {
    @concurrent func listCalendars(accountID: String) async throws(GoogleAPIError) -> (entries: [CalendarAPICalendarListEntry], syncToken: String?)
    @concurrent func syncCalendars(accountID: String, syncToken: String) async throws(GoogleAPIError) -> (entries: [CalendarAPICalendarListEntry], syncToken: String?)
}

// MARK: - CalendarEventService conformance

extension CalendarEventService: CalendarEventReading {}
extension CalendarEventService: CalendarEventMutating {}

// MARK: - CalendarListService conformance

extension CalendarListService: CalendarListReading {}
