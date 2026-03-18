import Foundation
internal import GRDB

struct CalendarRecord: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
    var id: String { "\(calendarId)_\(accountId)" }

    static let databaseTableName = "calendars"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    let calendarId: String
    let accountId: String
    var summary: String
    var description: String?
    var timeZone: String?
    var backgroundColor: String
    var foregroundColor: String
    var isPrimary: Bool
    var accessRole: String
    var isVisible: Bool
    var summaryOverride: String?
    var syncToken: String?
    var lastSyncedAt: Double?
}
