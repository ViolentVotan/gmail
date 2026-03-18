import AppIntents
import Foundation
private import GRDB

// MARK: - Show Upcoming Events

struct ShowUpcomingEventsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Upcoming Events"
    static let description: IntentDescription = "Shows your upcoming calendar events"
    static let openAppWhenRun = false

    @Parameter(title: "Number of Events", default: 5)
    var count: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let events = try await CalendarIntentHelpers.upcomingEvents(limit: count)
        guard !events.isEmpty else {
            return .result(dialog: "You have no upcoming events.")
        }
        let lines = events.map { CalendarIntentHelpers.formatEvent($0) }
        let summary = lines.joined(separator: "\n")
        return .result(dialog: "\(summary)")
    }
}

// MARK: - Create Calendar Event

struct CreateCalendarEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Calendar Event"
    static let description: IntentDescription = "Creates a new event on your calendar"
    static let openAppWhenRun = false

    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Start Date")
    var startDate: Date

    @Parameter(title: "End Date")
    var endDate: Date?

    @Parameter(title: "Location")
    var location: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let (calendarId, accountID) = await CalendarIntentHelpers.primaryCalendar() else {
            throw CalendarIntentError.noPrimaryCalendar
        }

        let resolvedEnd = endDate ?? startDate.addingTimeInterval(3600)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let event = CalendarAPIEventInput(
            summary: title,
            description: nil,
            location: location,
            start: CalendarAPIDateTime(date: nil, dateTime: f.string(from: startDate), timeZone: TimeZone.current.identifier),
            end: CalendarAPIDateTime(date: nil, dateTime: f.string(from: resolvedEnd), timeZone: TimeZone.current.identifier),
            attendees: nil,
            reminders: nil,
            conferenceData: nil,
            colorId: nil,
            recurrence: nil,
            transparency: nil,
            visibility: nil,
            guestsCanModify: nil,
            guestsCanInviteOthers: nil,
            extendedProperties: nil,
            attachments: nil
        )

        _ = try await CalendarEventService.shared.insertEvent(
            calendarId: calendarId,
            event: event,
            accountID: accountID
        )

        let endFormatted = DateFormatter.localizedString(from: resolvedEnd, dateStyle: .none, timeStyle: .short)
        let startFormatted = DateFormatter.localizedString(from: startDate, dateStyle: .medium, timeStyle: .short)
        return .result(dialog: "Created \"\(title)\" on \(startFormatted) - \(endFormatted).")
    }
}

// MARK: - RSVP to Event

struct RSVPToEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Respond to Calendar Event"
    static let description: IntentDescription = "Accept, decline, or tentatively accept a calendar event"
    static let openAppWhenRun = false

    @Parameter(title: "Event Title")
    var eventTitle: String

    @Parameter(title: "Response")
    var response: CalendarResponseEnum

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let match = try await CalendarIntentHelpers.findEvent(titled: eventTitle) else {
            throw CalendarIntentError.eventNotFound
        }
        _ = try await CalendarEventService.shared.respondToEvent(
            calendarId: match.calendarId,
            eventId: match.eventId,
            accountID: match.accountId,
            status: response.apiValue
        )
        let verb: String = switch response {
        case .accept: "Accepted"
        case .decline: "Declined"
        case .maybe: "Tentatively accepted"
        }
        return .result(dialog: "\(verb) \"\(match.summary)\".")
    }
}

// MARK: - Check Availability

struct CheckAvailabilityIntent: AppIntent {
    static let title: LocalizedStringResource = "Check My Availability"
    static let description: IntentDescription = "Check if you're free at a specific time"
    static let openAppWhenRun = false

    @Parameter(title: "Date and Time")
    var date: Date

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let windowStart = date.addingTimeInterval(-1800)
        let windowEnd = date.addingTimeInterval(1800)
        let conflicts = try await CalendarIntentHelpers.eventsOverlapping(start: windowStart, end: windowEnd)

        let formatted = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        if conflicts.isEmpty {
            return .result(dialog: "You're free at \(formatted).")
        }
        let titles = conflicts.compactMap { $0.summary }.prefix(3).joined(separator: ", ")
        return .result(dialog: "You're busy at \(formatted): \(titles).")
    }
}

// MARK: - CalendarResponseEnum

enum CalendarResponseEnum: String, AppEnum {
    case accept
    case decline
    case maybe

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Calendar Response")
    static let caseDisplayRepresentations: [CalendarResponseEnum: DisplayRepresentation] = [
        .accept: "Accept",
        .decline: "Decline",
        .maybe: "Maybe",
    ]

    var apiValue: String {
        switch self {
        case .accept: "accepted"
        case .decline: "declined"
        case .maybe: "tentative"
        }
    }
}

// MARK: - CalendarIntentError

enum CalendarIntentError: Error, LocalizedError {
    case noPrimaryCalendar
    case eventNotFound

    var errorDescription: String? {
        switch self {
        case .noPrimaryCalendar:
            "No primary calendar found. Please add a Google account first."
        case .eventNotFound:
            "No upcoming event with that title was found."
        }
    }
}

// MARK: - CalendarIntentHelpers

private struct EventMatch {
    let eventId: String
    let calendarId: String
    let accountId: String
    let summary: String
}

private enum CalendarIntentHelpers {

    /// Returns the primary calendarId and accountID for the first account that has one.
    static func primaryCalendar() async -> (calendarId: String, accountID: String)? {
        let accounts = await MainActor.run { AccountStore.shared.accounts }
        for account in accounts {
            guard let db = try? MailDatabase.shared(for: account.id) else { continue }
            let calendars = try? await db.dbPool.read { database in
                try MailDatabaseQueries.calendars(accountId: account.id, in: database)
            }
            if let primary = calendars?.first(where: { $0.isPrimary }) {
                return (primary.calendarId, account.id)
            }
            if let first = calendars?.first {
                return (first.calendarId, account.id)
            }
        }
        return nil
    }

    /// Fetches up to `limit` upcoming events from the local database across all accounts.
    static func upcomingEvents(limit: Int) async throws -> [CalendarEventRecord] {
        let accounts = await MainActor.run { AccountStore.shared.accounts }
        let now = Date().timeIntervalSince1970
        let futureEnd = now + 7 * 86400 // next 7 days

        var results: [CalendarEventRecord] = []
        for account in accounts {
            guard let db = try? MailDatabase.shared(for: account.id) else { continue }
            let events = try? await db.dbPool.read { database in
                try CalendarEventRecord
                    .filter(Column("account_id") == account.id)
                    .filter(Column("start_time") >= now)
                    .filter(Column("start_time") <= futureEnd)
                    .order(Column("start_time").asc)
                    .limit(limit)
                    .fetchAll(database)
            }
            results.append(contentsOf: events ?? [])
        }

        return Array(
            results
                .sorted { $0.startTime < $1.startTime }
                .prefix(limit)
        )
    }

    /// Finds an upcoming event by fuzzy title match (case-insensitive contains).
    static func findEvent(titled title: String) async throws -> EventMatch? {
        let accounts = await MainActor.run { AccountStore.shared.accounts }
        let now = Date().timeIntervalSince1970
        let lowered = title.lowercased()

        for account in accounts {
            guard let db = try? MailDatabase.shared(for: account.id) else { continue }
            let events = try? await db.dbPool.read { database in
                try CalendarEventRecord
                    .filter(Column("account_id") == account.id)
                    .filter(Column("start_time") >= now)
                    .order(Column("start_time").asc)
                    .limit(100)
                    .fetchAll(database)
            }
            guard let events else { continue }
            if let match = events.first(where: { ($0.summary ?? "").lowercased().contains(lowered) }) {
                return EventMatch(
                    eventId: match.eventId,
                    calendarId: match.calendarId,
                    accountId: match.accountId,
                    summary: match.summary ?? title
                )
            }
        }
        return nil
    }

    /// Returns events that overlap the given half-open interval [start, end) across all accounts.
    static func eventsOverlapping(start: Date, end: Date) async throws -> [CalendarEventRecord] {
        let accounts = await MainActor.run { AccountStore.shared.accounts }
        let startTs = start.timeIntervalSince1970
        let endTs = end.timeIntervalSince1970

        var results: [CalendarEventRecord] = []
        for account in accounts {
            guard let db = try? MailDatabase.shared(for: account.id) else { continue }
            let events = try? await db.dbPool.read { database in
                try CalendarEventRecord
                    .filter(Column("account_id") == account.id)
                    .filter(Column("start_time") < endTs)
                    .filter(Column("end_time") > startTs)
                    .order(Column("start_time").asc)
                    .fetchAll(database)
            }
            results.append(contentsOf: events ?? [])
        }
        return results.sorted { $0.startTime < $1.startTime }
    }

    /// Formats a CalendarEventRecord into a short human-readable line.
    static func formatEvent(_ event: CalendarEventRecord) -> String {
        let title = event.summary ?? "Untitled"
        let date = Date(timeIntervalSince1970: event.startTime)
        let formatted = DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: event.isAllDay ? .none : .short)
        return "• \(title) — \(formatted)"
    }
}
