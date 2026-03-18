import Foundation

// MARK: - Response Wrappers

struct CalendarEventListResponse: Codable, Sendable {
    let items:          [CalendarAPIEvent]?
    let nextPageToken:  String?
    let nextSyncToken:  String?
    let kind:           String?
    let summary:        String?
    let timeZone:       String?
    let updated:        String?
}

struct CalendarAPICalendarListResponse: Codable, Sendable {
    let items:          [CalendarAPICalendarListEntry]?
    let nextPageToken:  String?
    let nextSyncToken:  String?
    let kind:           String?
}

struct CalendarListSyncResponse: Codable, Sendable {
    let items:         [CalendarAPICalendarListEntry]?
    let nextPageToken: String?
    let nextSyncToken: String?
    let kind:          String?
}

// MARK: - Core Resources

struct CalendarAPIEvent: Codable, Sendable {
    let id:                         String?
    let status:                     String?
    let htmlLink:                   String?
    let created:                    String?
    let updated:                    String?
    let summary:                    String?
    let description:                String?
    let location:                   String?
    let colorId:                    String?
    let creator:                    CalendarAPIPerson?
    let organizer:                  CalendarAPIPerson?
    let start:                      CalendarAPIDateTime?
    let end:                        CalendarAPIDateTime?
    let recurrence:                 [String]?
    let recurringEventId:           String?
    let originalStartTime:          CalendarAPIDateTime?
    let transparency:               String?
    let visibility:                 String?
    let iCalUID:                    String?
    let sequence:                   Int?
    let attendees:                  [CalendarAPIAttendee]?
    let attendeesOmitted:           Bool?
    let conferenceData:             CalendarAPIConferenceData?
    let reminders:                  CalendarAPIReminders?
    let attachments:                [CalendarAPIAttachment]?
    let eventType:                  String?
    let etag:                       String?
    let hangoutLink:                String?
    let guestsCanModify:            Bool?
    let guestsCanInviteOthers:      Bool?
    let guestsCanSeeOtherGuests:    Bool?
    let extendedProperties:         CalendarAPIExtendedProperties?
    /// Whether the authenticated user is the event creator (API field: "self").
    let isSelf:                     Bool?

    private enum CodingKeys: String, CodingKey {
        case id, status, htmlLink, created, updated, summary, description, location, colorId
        case creator, organizer, start, end, recurrence, recurringEventId, originalStartTime
        case transparency, visibility, iCalUID, sequence, attendees, attendeesOmitted
        case conferenceData, reminders, attachments, eventType, etag, hangoutLink
        case guestsCanModify, guestsCanInviteOthers, guestsCanSeeOtherGuests
        case extendedProperties
        case isSelf = "self"
    }
}

struct CalendarAPIDateTime: Codable, Sendable {
    /// Date string in "yyyy-MM-dd" format — present for all-day events.
    let date:     String?
    /// RFC3339 date-time string — present for timed events.
    let dateTime: String?
    let timeZone: String?
}

struct CalendarAPIPerson: Codable, Sendable {
    let email:       String?
    let displayName: String?
    /// Whether this person is the authenticated user (API field: "self").
    let isSelf:      Bool?

    private enum CodingKeys: String, CodingKey {
        case email, displayName
        case isSelf = "self"
    }
}

struct CalendarAPIAttendee: Codable, Sendable {
    let email:          String?
    let displayName:    String?
    let responseStatus: String?
    let organizer:      Bool?
    let resource:       Bool?
    let optional:       Bool?
    let comment:        String?
    let additionalGuests: Int?
    /// Whether this attendee is the authenticated user (API field: "self").
    let isSelf:         Bool?

    private enum CodingKeys: String, CodingKey {
        case email, displayName, responseStatus, organizer, resource
        case optional, comment, additionalGuests
        case isSelf = "self"
    }
}

struct CalendarAPICalendarListEntry: Codable, Sendable {
    let id:                   String?
    let summary:              String?
    let description:          String?
    let location:             String?
    let timeZone:             String?
    let summaryOverride:      String?
    let colorId:              String?
    let backgroundColor:      String?
    let foregroundColor:      String?
    let hidden:               Bool?
    let selected:             Bool?
    let accessRole:           String?
    let primary:              Bool?
    let deleted:              Bool?
    let defaultReminders:     [CalendarAPIReminderOverride]?
    let conferenceProperties: CalendarAPIConferenceProperties?
}

// MARK: - Conference Types

struct CalendarAPIConferenceData: Codable, Sendable {
    let entryPoints:        [CalendarAPIConferenceEntryPoint]?
    let conferenceSolution:  CalendarAPIConferenceSolution?
    let conferenceId:        String?
    let signature:           String?
    let notes:               String?
}

struct CalendarAPIConferenceEntryPoint: Codable, Sendable {
    let entryPointType: String?
    let uri:            String?
    let label:          String?
    let pin:            String?
    let meetingCode:    String?
    let passcode:       String?
    let password:       String?
    let regionCode:     String?
}

struct CalendarAPIConferenceSolution: Codable, Sendable {
    let key:     CalendarAPIConferenceSolutionKey?
    let name:    String?
    let iconUri: String?
}

struct CalendarAPIConferenceSolutionKey: Codable, Sendable {
    let type: String?
}

struct CalendarAPIConferenceProperties: Codable, Sendable {
    let allowedConferenceSolutionTypes: [String]?
}

// MARK: - Reminder Types

struct CalendarAPIReminders: Codable, Sendable {
    let useDefault: Bool?
    let overrides:  [CalendarAPIReminderOverride]?
}

struct CalendarAPIReminderOverride: Codable, Sendable {
    let method:  String?
    let minutes: Int?
}

// MARK: - Attachment & Properties

struct CalendarAPIAttachment: Codable, Sendable {
    let fileUrl:  String?
    let title:    String?
    let mimeType: String?
    let iconLink: String?
    let fileId:   String?
}

struct CalendarAPIExtendedProperties: Codable, Sendable {
    /// Per-attendee private properties (API field: "private").
    let privateProperties: [String: String]?
    let shared:             [String: String]?

    private enum CodingKeys: String, CodingKey {
        case privateProperties = "private"
        case shared
    }
}

// MARK: - Colors

struct CalendarAPIColors: Codable, Sendable {
    let calendar: [String: CalendarAPIColorEntry]?
    let event:    [String: CalendarAPIColorEntry]?
    let kind:     String?
    let updated:  String?
}

struct CalendarAPIColorEntry: Codable, Sendable {
    let background:  String?
    let foreground:  String?
}

// MARK: - Settings

struct CalendarAPISetting: Codable, Sendable {
    let id:    String?
    let value: String?
    let kind:  String?
    let etag:  String?
}

struct CalendarAPISettingsListResponse: Codable, Sendable {
    let items:         [CalendarAPISetting]?
    let nextPageToken: String?
    let nextSyncToken: String?
    let kind:          String?
    let etag:          String?
}

// MARK: - Free/Busy

struct CalendarAPIFreeBusyRequest: Codable, Sendable {
    let timeMin:  String
    let timeMax:  String
    let timeZone: String?
    let items:    [CalendarAPIFreeBusyRequestItem]
}

struct CalendarAPIFreeBusyRequestItem: Codable, Sendable {
    let id: String
}

struct CalendarAPIFreeBusyResponse: Codable, Sendable {
    let calendars: [String: CalendarAPIFreeBusyCalendar]?
    let timeMin:   String?
    let timeMax:   String?
    let kind:      String?
}

struct CalendarAPIFreeBusyCalendar: Codable, Sendable {
    let busy:   [CalendarAPIFreeBusyTimeRange]?
    let errors: [CalendarAPIFreeBusyError]?
}

struct CalendarAPIFreeBusyTimeRange: Codable, Sendable {
    let start: String?
    let end:   String?
}

struct CalendarAPIFreeBusyError: Codable, Sendable {
    let domain: String?
    let reason: String?
}

// MARK: - Input Types (for create/update requests)

struct CalendarAPIEventInput: Codable, Sendable {
    var summary:                 String?
    var description:             String?
    var location:                String?
    var start:                   CalendarAPIDateTime?
    var end:                     CalendarAPIDateTime?
    var attendees:               [CalendarAPIAttendeeInput]?
    var reminders:               CalendarAPIReminders?
    var conferenceData:          CalendarAPIConferenceData?
    var colorId:                 String?
    var recurrence:              [String]?
    var transparency:            String?
    var visibility:              String?
    var guestsCanModify:         Bool?
    var guestsCanInviteOthers:   Bool?
    var extendedProperties:      CalendarAPIExtendedProperties?
    var attachments:             [CalendarAPIAttachment]?
}

/// Writable attendee fields for event create/update requests.
struct CalendarAPIAttendeeInput: Codable, Sendable {
    var email:       String
    var displayName: String?
    var optional:    Bool?
    var comment:     String?
}
