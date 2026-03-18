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

    init(from event: CalendarEvent) {
        summary = event.summary
        description = event.description
        location = event.location
        startTime = event.startTime
        endTime = event.endTime
        isAllDay = event.isAllDay
        attendeeEmails = event.attendees.map(\.email)
        colorId = event.colorId
    }
}
