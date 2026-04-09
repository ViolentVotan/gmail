import Foundation

// MARK: - Event Edit Draft

struct EventEditDraft: Equatable {
    var summary: String
    var description: String?
    var location: String?
    var startTime: Date
    var endTime: Date
    var isAllDay: Bool
    var attendeeEmails: [String]
    var reminders: [EventReminder]
    var hasConferenceLink: Bool
    var colorId: String?
    var calendarId: String
    var isRecurring: Bool
    var googleEventId: String
    var accountID: String
    var etag: String?

    init(
        summary: String,
        description: String?,
        location: String?,
        startTime: Date,
        endTime: Date,
        isAllDay: Bool,
        attendeeEmails: [String],
        reminders: [EventReminder],
        hasConferenceLink: Bool,
        colorId: String?,
        calendarId: String,
        isRecurring: Bool,
        googleEventId: String,
        accountID: String,
        etag: String?
    ) {
        self.summary = summary
        self.description = description
        self.location = location
        self.startTime = startTime
        self.endTime = endTime
        self.isAllDay = isAllDay
        self.attendeeEmails = attendeeEmails
        self.reminders = reminders
        self.hasConferenceLink = hasConferenceLink
        self.colorId = colorId
        self.calendarId = calendarId
        self.isRecurring = isRecurring
        self.googleEventId = googleEventId
        self.accountID = accountID
        self.etag = etag
    }

    init(from event: CalendarEvent) {
        summary = event.summary
        description = event.description
        location = event.location
        startTime = event.startTime
        endTime = event.endTime
        isAllDay = event.isAllDay
        attendeeEmails = event.attendees.map(\.email)
        reminders = event.reminders
        hasConferenceLink = event.conferenceLink != nil
        colorId = event.colorId
        calendarId = event.calendarId
        isRecurring = event.isRecurring
        googleEventId = event.googleEventId
        accountID = event.accountID
        etag = event.etag
    }
}
