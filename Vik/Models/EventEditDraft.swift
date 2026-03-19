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
    var colorId: String?
    var calendarId: String
    var isRecurring: Bool
    var googleEventId: String
    var accountID: String
    var etag: String?

    init(from event: CalendarEvent) {
        summary = event.summary
        description = event.description
        location = event.location
        startTime = event.startTime
        endTime = event.endTime
        isAllDay = event.isAllDay
        attendeeEmails = event.attendees.map(\.email)
        colorId = event.colorId
        calendarId = event.calendarId
        isRecurring = event.isRecurring
        googleEventId = event.googleEventId
        accountID = event.accountID
        etag = event.etag
    }
}
