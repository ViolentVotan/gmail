import Foundation
internal import GRDB

struct CalendarEventRecord: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
    var id: String { "\(eventId)_\(calendarId)_\(accountId)" }

    static let databaseTableName = "calendar_events"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    let eventId: String
    let calendarId: String
    let accountId: String
    var summary: String?
    var description: String?
    var location: String?
    var startTime: Double
    var endTime: Double
    var isAllDay: Bool
    var timeZone: String?
    var status: String
    var organizerEmail: String?
    var organizerName: String?
    var organizerIsSelf: Bool
    var creatorEmail: String?
    var selfResponseStatus: String?
    var colorId: String?
    var isRecurring: Bool
    var recurringEventId: String?
    var conferenceLink: String?
    var conferenceName: String?
    var eventType: String
    var etag: String
    var htmlLink: String?
    var canEdit: Bool
    var iCalUid: String?
    var sequence: Int?
    var remindersJson: String?
    var attachmentsJson: String?
    var extendedPropertiesJson: String?
    var updatedAt: Double
}
