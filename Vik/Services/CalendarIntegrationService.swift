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
            let events = try await db.dbPool.read { dbConnection -> [CalendarEventRecord] in
                var seen = Set<String>()
                var result: [CalendarEventRecord] = []
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
                        result.append(record)
                    }
                }
                return result
            }

            guard !events.isEmpty else { return [] }

            // Batch-fetch all attendees for collected events in a single query.
            let compositeKeys = events.map { ($0.eventId, $0.calendarId, $0.accountId) }
            let allAttendees: [CalendarAttendeeRecord] = (try? await db.dbPool.read { dbConnection in
                let placeholders = compositeKeys.map { _ in "(?, ?, ?)" }.joined(separator: ", ")
                let args = compositeKeys.flatMap { [$0.0 as (any DatabaseValueConvertible), $0.1, $0.2] }
                return try CalendarAttendeeRecord.filter(
                    sql: "(event_id, calendar_id, account_id) IN (\(placeholders))",
                    arguments: StatementArguments(args)
                ).fetchAll(dbConnection)
            }) ?? []

            // Group attendees by composite key for O(1) lookup.
            let attendeesByKey = Dictionary(grouping: allAttendees) {
                "\($0.eventId)\u{001F}\($0.calendarId)\u{001F}\($0.accountId)"
            }

            return events
                .map { record in
                    let key = "\(record.eventId)\u{001F}\(record.calendarId)\u{001F}\(record.accountId)"
                    return record.toCalendarEvent(attendees: attendeesByKey[key] ?? [], calendarColor: .accentColor)
                }
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
