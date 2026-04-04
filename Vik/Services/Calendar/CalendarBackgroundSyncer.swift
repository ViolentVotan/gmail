import Foundation
internal import GRDB
private import os

/// Actor responsible for bulk calendar database writes during sync.
/// All heavy calendar I/O (upsert calendars, events, attendees) goes through this actor
/// to serialize writes and keep the main actor free for UI work.
actor CalendarBackgroundSyncer {
    private let db: MailDatabase
    nonisolated private static let logger = Logger(category: "CalendarBackgroundSyncer")

    init(db: MailDatabase) {
        self.db = db
    }

    // MARK: - Calendar Upsert

    /// Upserts calendar list entries into the database.
    /// Preserves existing `syncToken` and `lastSyncedAt` values when not provided
    /// in the incoming records (calendar list API doesn't return per-calendar sync tokens).
    func upsertCalendars(_ calendars: [CalendarRecord]) async throws {
        guard !calendars.isEmpty else { return }
        assert(
            calendars.allSatisfy { $0.accountId == calendars[0].accountId },
            "upsertCalendars requires all calendars to share the same accountId"
        )
        try await db.dbPool.write { db in
            // Batch-prefetch all existing calendars for this account in one query
            // to avoid N+1 individual fetchOne calls inside the loop.
            let accountId = calendars[0].accountId
            let existingRecords = try CalendarRecord
                .filter(Column("account_id") == accountId)
                .fetchAll(db)
            let existingMap = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.calendarId, $0) })

            for var calendar in calendars {
                // Preserve existing sync metadata if present
                if let existing = existingMap[calendar.calendarId] {
                    if calendar.syncToken == nil { calendar.syncToken = existing.syncToken }
                    if calendar.lastSyncedAt == nil { calendar.lastSyncedAt = existing.lastSyncedAt }
                    // Preserve local visibility preference — isVisible is treated as a
                    // local-only toggle once the calendar exists. Server-side `hidden`
                    // changes from other clients are intentionally not synced back.
                    calendar.isVisible = existing.isVisible
                }
                try calendar.upsert(db)
            }
        }
    }

    // MARK: - Calendar Deletion

    /// Deletes calendars by (calendarId, accountId) pairs.
    /// Cascading foreign keys handle related events and attendees.
    func deleteCalendars(_ ids: [(calendarId: String, accountId: String)]) async throws {
        guard !ids.isEmpty else { return }
        try await db.dbPool.write { db in
            // Single DELETE with OR-chained compound predicates — one round trip for all pairs.
            let conditions = ids.map { _ in "(calendar_id = ? AND account_id = ?)" }.joined(separator: " OR ")
            let args: [DatabaseValueConvertible] = ids.flatMap { [$0.calendarId, $0.accountId] }
            try db.execute(
                sql: "DELETE FROM calendars WHERE \(conditions)",
                arguments: StatementArguments(args)
            )
        }
    }

    // MARK: - Event Upsert

    /// Upserts events and their attendees in a single transaction.
    /// Replaces existing attendees for each upserted event to ensure consistency.
    func upsertEvents(_ events: [CalendarEventRecord], attendees: [CalendarAttendeeRecord]) async throws {
        guard !events.isEmpty else { return }
        try await db.dbPool.write { db in
            // Track which events we've already cleared attendees for
            // to avoid redundant deletes when the same event appears multiple times.
            var clearedEvents: Set<EventKey> = []

            for event in events {
                try event.upsert(db)

                let key = EventKey(eventId: event.eventId, calendarId: event.calendarId, accountId: event.accountId)
                if clearedEvents.insert(key).inserted {
                    try CalendarAttendeeRecord
                        .filter(Column("event_id") == event.eventId)
                        .filter(Column("calendar_id") == event.calendarId)
                        .filter(Column("account_id") == event.accountId)
                        .deleteAll(db)
                }
            }

            for attendee in attendees {
                try attendee.save(db, onConflict: .replace)
            }
        }
    }

    // MARK: - Event Deletion

    /// Deletes events by (eventId, calendarId, accountId) tuples.
    /// Cascading foreign keys handle related attendees.
    func deleteEvents(_ ids: [(eventId: String, calendarId: String, accountId: String)]) async throws {
        guard !ids.isEmpty else { return }
        try await db.dbPool.write { db in
            // Single DELETE with OR-chained compound predicates — one round trip for all tuples.
            let conditions = ids.map { _ in "(event_id = ? AND calendar_id = ? AND account_id = ?)" }.joined(separator: " OR ")
            let args: [DatabaseValueConvertible] = ids.flatMap { [$0.eventId, $0.calendarId, $0.accountId] }
            try db.execute(
                sql: "DELETE FROM calendar_events WHERE \(conditions)",
                arguments: StatementArguments(args)
            )
        }
    }

    // MARK: - Bulk Event Deletion

    /// Deletes all events for a calendar (cascading FKs handle attendees).
    /// Used before full resync after a 410 (sync token expired).
    func deleteEventsForCalendar(calendarId: String, accountId: String) async throws {
        _ = try await db.dbPool.write { db in
            try CalendarEventRecord
                .filter(Column("calendar_id") == calendarId)
                .filter(Column("account_id") == accountId)
                .deleteAll(db)
        }
    }

    // MARK: - Sync Token

    /// Updates the sync token and last-synced timestamp for a calendar.
    func updateSyncToken(calendarId: String, accountId: String, token: String) async throws {
        try await db.dbPool.write { db in
            try MailDatabaseQueries.updateCalendarSyncToken(
                calendarId: calendarId, accountId: accountId, token: token, in: db
            )
        }
    }

    // MARK: - Optimistic Writes

    /// Snapshots and deletes an event atomically in a single write transaction.
    /// Returns the snapshot (event record + attendees) for rollback, or `nil` if the event was not found.
    func optimisticDeleteEvent(
        eventId: String,
        calendarId: String,
        accountId: String
    ) async throws -> (CalendarEventRecord, [CalendarAttendeeRecord])? {
        try await db.dbPool.write { db in
            guard let eventRecord = try CalendarEventRecord
                .filter(Column("event_id") == eventId
                    && Column("calendar_id") == calendarId
                    && Column("account_id") == accountId)
                .fetchOne(db)
            else { return nil }
            let attendees = try CalendarAttendeeRecord
                .filter(Column("event_id") == eventId
                    && Column("calendar_id") == calendarId
                    && Column("account_id") == accountId)
                .fetchAll(db)
            try MailDatabaseQueries.deleteCalendarEvent(
                eventId: eventId, calendarId: calendarId, accountId: accountId, in: db
            )
            return (eventRecord, attendees)
        }
    }

    /// Re-inserts a previously deleted event and its attendees (rollback after API failure).
    func rollbackDeleteEvent(
        _ eventRecord: CalendarEventRecord,
        attendees: [CalendarAttendeeRecord]
    ) async throws {
        try await db.dbPool.write { db in
            try eventRecord.insert(db)
            for attendee in attendees { try attendee.insert(db) }
        }
    }

    /// Optimistically updates the RSVP status for an event in the database.
    func optimisticUpdateRSVP(
        eventId: String,
        calendarId: String,
        accountId: String,
        status: String
    ) async throws {
        try await db.dbPool.write { db in
            try MailDatabaseQueries.updateCalendarEventRSVP(
                eventId: eventId, calendarId: calendarId, accountId: accountId, status: status, in: db
            )
        }
    }

    /// Restores the original RSVP status for an event (rollback after API failure).
    func rollbackRSVP(
        eventId: String,
        calendarId: String,
        accountId: String,
        originalStatus: String
    ) async throws {
        try await db.dbPool.write { db in
            try MailDatabaseQueries.updateCalendarEventRSVP(
                eventId: eventId, calendarId: calendarId, accountId: accountId, status: originalStatus, in: db
            )
        }
    }

    // MARK: - Private Types

    /// Hashable key for deduplicating events by their composite primary key.
    private struct EventKey: Hashable {
        let eventId: String
        let calendarId: String
        let accountId: String
    }
}
