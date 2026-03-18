import Foundation
internal import GRDB
private import os

/// Actor responsible for bulk calendar database writes during sync.
/// All heavy calendar I/O (upsert calendars, events, attendees) goes through this actor
/// to serialize writes and keep the main actor free for UI work.
actor CalendarBackgroundSyncer {
    private let db: MailDatabase
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "CalendarBackgroundSyncer")

    init(db: MailDatabase) {
        self.db = db
    }

    // MARK: - Calendar Upsert

    /// Upserts calendar list entries into the database.
    /// Preserves existing `syncToken` and `lastSyncedAt` values when not provided
    /// in the incoming records (calendar list API doesn't return per-calendar sync tokens).
    func upsertCalendars(_ calendars: [CalendarRecord]) async throws {
        guard !calendars.isEmpty else { return }
        try await db.dbPool.write { db in
            for var calendar in calendars {
                // Preserve existing sync metadata if present
                if let existing = try CalendarRecord
                    .filter(Column("calendar_id") == calendar.calendarId)
                    .filter(Column("account_id") == calendar.accountId)
                    .fetchOne(db) {
                    if calendar.syncToken == nil { calendar.syncToken = existing.syncToken }
                    if calendar.lastSyncedAt == nil { calendar.lastSyncedAt = existing.lastSyncedAt }
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
            for id in ids {
                try CalendarRecord
                    .filter(Column("calendar_id") == id.calendarId)
                    .filter(Column("account_id") == id.accountId)
                    .deleteAll(db)
            }
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
                try event.save(db, onConflict: .replace)

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
            for id in ids {
                try CalendarEventRecord
                    .filter(Column("event_id") == id.eventId)
                    .filter(Column("calendar_id") == id.calendarId)
                    .filter(Column("account_id") == id.accountId)
                    .deleteAll(db)
            }
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

    // MARK: - Private Types

    /// Hashable key for deduplicating events by their composite primary key.
    private struct EventKey: Hashable {
        let eventId: String
        let calendarId: String
        let accountId: String
    }
}
