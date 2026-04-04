import Foundation
internal import GRDB

struct CalendarAttendeeRecord: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
    var id: String { "\(eventId)||\(calendarId)||\(accountId)||\(email)" }

    static let databaseTableName = "calendar_attendees"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    let eventId: String
    let calendarId: String
    let accountId: String
    let email: String
    var displayName: String?
    var responseStatus: String
    var isOrganizer: Bool
    var isResource: Bool
    var isOptional: Bool
}
