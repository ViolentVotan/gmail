import Foundation
private import GRDB
private import os

final class CalendarIntegrationService: Sendable {
    static let shared = CalendarIntegrationService()
    nonisolated private static let logger = Logger(category: "CalendarIntegration")
    private init() {}

    // MARK: - Invite Matching

    /// Finds the calendar event matching an email invite by iCalUID.
    @concurrent func findEventForInvite(iCalUID: String, accountID: String, db: MailDatabase) async -> CalendarEvent? {
        do {
            let result = try await db.dbPool.read { dbConnection in
                let record = try CalendarEventRecord
                    .filter(Column("i_cal_uid") == iCalUID)
                    .filter(Column("account_id") == accountID)
                    .fetchOne(dbConnection)
                guard let record else { return nil as (CalendarEventRecord, [CalendarAttendeeRecord])? }
                let attendees = try CalendarAttendeeRecord
                    .filter(Column("event_id") == record.eventId)
                    .filter(Column("calendar_id") == record.calendarId)
                    .filter(Column("account_id") == record.accountId)
                    .fetchAll(dbConnection)
                return (record, attendees)
            }
            guard let (record, attendees) = result else { return nil }
            return record.toCalendarEvent(attendees: attendees, calendarColor: .accentColor)
        } catch {
            Self.logger.error("findEventForInvite failed: \(error)")
            return nil
        }
    }

    // MARK: - Participant Matching

    /// Finds upcoming events (within 48h) that include any of the given participant emails.
    @concurrent func findUpcomingEventsWithParticipants(
        emails: [String],
        accountID: String,
        db: MailDatabase,
        limit: Int = 3
    ) async -> [CalendarEvent] {
        guard !emails.isEmpty else { return [] }
        let cutoff = Date().addingTimeInterval(48 * 3600).timeIntervalSince1970

        do {
            let merged = try await db.dbPool.read { dbConnection -> [(CalendarEventRecord, [CalendarAttendeeRecord])] in
                var seen = Set<String>()
                var result: [(CalendarEventRecord, [CalendarAttendeeRecord])] = []
                for email in emails {
                    let records = try MailDatabaseQueries.upcomingEventsWithParticipant(
                        email: email,
                        accountId: accountID,
                        limit: limit,
                        in: dbConnection
                    )
                    for record in records {
                        guard record.startTime <= cutoff else { continue }
                        guard !seen.contains(record.eventId) else { continue }
                        seen.insert(record.eventId)
                        let attendees = try CalendarAttendeeRecord
                            .filter(Column("event_id") == record.eventId)
                            .filter(Column("calendar_id") == record.calendarId)
                            .filter(Column("account_id") == record.accountId)
                            .fetchAll(dbConnection)
                        result.append((record, attendees))
                    }
                }
                return result
            }

            return merged
                .map { $0.toCalendarEvent(attendees: $1, calendarColor: .accentColor) }
                .sorted { $0.startTime < $1.startTime }
                .prefix(limit)
                .map { $0 }
        } catch {
            Self.logger.error("findUpcomingEventsWithParticipants failed: \(error)")
            return []
        }
    }

    // MARK: - Next Meeting

    /// Finds the next upcoming meeting with a specific person.
    @concurrent func nextMeetingWith(email: String, accountID: String, db: MailDatabase) async -> CalendarEvent? {
        await findUpcomingEventsWithParticipants(emails: [email], accountID: accountID, db: db, limit: 1).first
    }
}
