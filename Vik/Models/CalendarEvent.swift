import SwiftUI

// MARK: - RSVP Status

/// Calendar RSVP status -- maps to Google Calendar API attendee responseStatus.
/// Replaces the old CalendarInvite.RSVPStatus (which used "maybe"/"pending").
enum CalendarRSVPStatus: String, Sendable, Codable {
    case needsAction, declined, tentative, accepted
}

// MARK: - Calendar Event

struct CalendarEvent: Identifiable, Sendable, Equatable {
    /// Synthetic unique ID: "\(accountID)_\(calendarId)_\(googleEventId)"
    let id: String
    let googleEventId: String
    let calendarId: String
    let accountID: String
    let summary: String
    let description: String?
    let location: String?
    let startTime: Date
    let endTime: Date
    let isAllDay: Bool
    let timeZone: String?
    let status: EventStatus
    let organizer: EventPerson?
    let creator: EventPerson?
    let attendees: [EventAttendee]
    let selfResponseStatus: CalendarRSVPStatus
    let conferenceLink: URL?
    let conferenceName: String?
    let colorId: String?
    let resolvedColor: Color
    let isRecurring: Bool
    let recurringEventId: String?
    let reminders: [EventReminder]
    let eventType: EventType
    let etag: String
    let htmlLink: URL?
    let canEdit: Bool
    let attachments: [EventAttachment]

    enum EventStatus: String, Sendable { case confirmed, tentative, cancelled }
    enum EventType: String, Sendable { case `default`, birthday, focusTime, fromGmail, outOfOffice, workingLocation }

    /// Compact: "2:30 – 3:30 PM" or "All day"
    var formattedTimeRangeCompact: String {
        isAllDay ? "All day" : "\(startTime.formattedCalendarTime) – \(endTime.formattedCalendarTimeAmPm)"
    }

    /// Full: "2:30 PM – 3:30 PM" or "All day"
    var formattedTimeRange: String {
        isAllDay ? "All day" : "\(startTime.formattedTime) – \(endTime.formattedTime)"
    }

    static func == (lhs: CalendarEvent, rhs: CalendarEvent) -> Bool {
        lhs.googleEventId == rhs.googleEventId &&
        lhs.calendarId == rhs.calendarId &&
        lhs.accountID == rhs.accountID &&
        lhs.summary == rhs.summary &&
        lhs.startTime == rhs.startTime &&
        lhs.endTime == rhs.endTime &&
        lhs.isAllDay == rhs.isAllDay &&
        lhs.status == rhs.status &&
        lhs.selfResponseStatus == rhs.selfResponseStatus &&
        lhs.colorId == rhs.colorId &&
        lhs.etag == rhs.etag
    }
}

// MARK: - Supporting Types

struct EventPerson: Sendable, Equatable {
    let email: String
    let displayName: String?
    let isSelf: Bool
}

struct EventAttendee: Identifiable, Sendable, Equatable {
    var id: String { email }
    let email: String
    let displayName: String?
    let responseStatus: CalendarRSVPStatus
    let isOrganizer: Bool
    let isResource: Bool
    let isOptional: Bool
}

struct EventReminder: Sendable, Equatable {
    let method: ReminderMethod
    let minutes: Int

    enum ReminderMethod: String, Sendable { case email, popup }
}

struct EventAttachment: Sendable, Equatable {
    let title: String
    let fileURL: URL?
    let mimeType: String?
    let iconURL: URL?
}

// MARK: - Calendar Info

struct CalendarInfo: Identifiable, Sendable, Equatable {
    let id: String
    let calendarId: String
    let accountID: String
    let summary: String
    let description: String?
    let timeZone: String?
    let backgroundColor: String
    let foregroundColor: String
    let isPrimary: Bool
    let accessRole: AccessRole
    var isVisible: Bool
    var summaryOverride: String?

    enum AccessRole: String, Sendable { case freeBusyReader, reader, writer, owner }
}

// MARK: - View Mode Enums

enum CalendarViewMode: String, Sendable {
    case month, week, day, agenda

    var label: String {
        switch self {
        case .month: "Month"
        case .day: "Day"
        case .week: "Week"
        case .agenda: "Agenda"
        }
    }
}

// MARK: - Record → Domain Conversions

extension CalendarEventRecord {
    private static let jsonDecoder = JSONDecoder()

    /// Converts a database record + attendee records into a domain `CalendarEvent`.
    /// The `calendarColor` is used as fallback when the event has no `colorId`.
    func toCalendarEvent(attendees: [CalendarAttendeeRecord], calendarColor: Color) -> CalendarEvent {
        let resolvedColor: Color = if let colorId {
            CalendarColor.color(forId: Int(colorId))
        } else {
            calendarColor
        }

        let reminders: [EventReminder] = if let remindersJson,
            let data = remindersJson.data(using: .utf8),
            let wrapper = try? Self.jsonDecoder.decode(RemindersWrapperJSON.self, from: data),
            let overrides = wrapper.overrides {
            overrides.map { EventReminder(
                method: EventReminder.ReminderMethod(rawValue: $0.method) ?? .popup,
                minutes: $0.minutes
            ) }
        } else {
            []
        }

        let attachments: [EventAttachment] = if let attachmentsJson,
            let data = attachmentsJson.data(using: .utf8),
            let parsed = try? Self.jsonDecoder.decode([AttachmentJSON].self, from: data) {
            parsed.map { EventAttachment(
                title: $0.title ?? "",
                fileURL: $0.fileUrl.flatMap { URL(string: $0) },
                mimeType: $0.mimeType,
                iconURL: $0.iconLink.flatMap { URL(string: $0) }
            ) }
        } else {
            []
        }

        var organizer: EventPerson?
        if let organizerEmail {
            organizer = EventPerson(
                email: organizerEmail,
                displayName: organizerName,
                isSelf: organizerIsSelf
            )
        }

        var creator: EventPerson?
        if let creatorEmail {
            creator = EventPerson(email: creatorEmail, displayName: nil, isSelf: false)
        }

        return CalendarEvent(
            id: "\(accountId)_\(calendarId)_\(eventId)",
            googleEventId: eventId,
            calendarId: calendarId,
            accountID: accountId,
            summary: summary ?? "",
            description: description,
            location: location,
            startTime: Date(timeIntervalSince1970: startTime),
            endTime: Date(timeIntervalSince1970: endTime),
            isAllDay: isAllDay,
            timeZone: timeZone,
            status: CalendarEvent.EventStatus(rawValue: status) ?? .confirmed,
            organizer: organizer,
            creator: creator,
            attendees: attendees.map { $0.toEventAttendee() },
            selfResponseStatus: CalendarRSVPStatus(rawValue: selfResponseStatus ?? "needsAction") ?? .needsAction,
            conferenceLink: conferenceLink.flatMap { URL(string: $0) },
            conferenceName: conferenceName,
            colorId: colorId,
            resolvedColor: resolvedColor,
            isRecurring: isRecurring,
            recurringEventId: recurringEventId,
            reminders: reminders,
            eventType: CalendarEvent.EventType(rawValue: eventType) ?? .default,
            etag: etag,
            htmlLink: htmlLink.flatMap { URL(string: $0) },
            canEdit: canEdit,
            attachments: attachments
        )
    }
}

extension CalendarAttendeeRecord {
    func toEventAttendee() -> EventAttendee {
        EventAttendee(
            email: email,
            displayName: displayName,
            responseStatus: CalendarRSVPStatus(rawValue: responseStatus) ?? .needsAction,
            isOrganizer: isOrganizer,
            isResource: isResource,
            isOptional: isOptional
        )
    }
}

extension CalendarRecord {
    func toCalendarInfo() -> CalendarInfo {
        CalendarInfo(
            id: "\(accountId)_\(calendarId)",
            calendarId: calendarId,
            accountID: accountId,
            summary: summary,
            description: description,
            timeZone: timeZone,
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            isPrimary: isPrimary,
            accessRole: CalendarInfo.AccessRole(rawValue: accessRole) ?? .reader,
            isVisible: isVisible,
            summaryOverride: summaryOverride
        )
    }
}

// MARK: - JSON Decodable Helpers (for reminders/attachments stored as JSON strings)

private struct RemindersWrapperJSON: Decodable {
    let useDefault: Bool?
    let overrides: [ReminderJSON]?
}

private struct ReminderJSON: Decodable {
    let method: String
    let minutes: Int
}

private struct AttachmentJSON: Decodable {
    let title: String?
    let fileUrl: String?
    let mimeType: String?
    let iconLink: String?
}

extension Array where Element == CalendarEvent {
    /// Single-pass partition into all-day and timed events.
    func partitioned() -> (allDay: [CalendarEvent], timed: [CalendarEvent]) {
        var allDay: [CalendarEvent] = []
        var timed: [CalendarEvent] = []
        for event in self {
            if event.isAllDay { allDay.append(event) }
            else { timed.append(event) }
        }
        return (allDay, timed)
    }
}
