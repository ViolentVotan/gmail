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
                }
                try calendar.save(db, onConflict: .replace)
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
            for event in events {
                try event.save(db, onConflict: .replace)
            }

            // Delete existing attendees per-event, then insert fresh ones.
            // Avoids complex multi-column IN clauses that may not work across SQLite versions.
            let eventKeys = Set(events.map { "\($0.eventId)|\($0.calendarId)|\($0.accountId)" })
            for key in eventKeys {
                let parts = key.split(separator: "|", maxSplits: 2)
                guard parts.count == 3 else { continue }
                try CalendarAttendeeRecord
                    .filter(Column("event_id") == String(parts[0]))
                    .filter(Column("calendar_id") == String(parts[1]))
                    .filter(Column("account_id") == String(parts[2]))
                    .deleteAll(db)
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

    // MARK: - Sync Token

    /// Updates the sync token and last-synced timestamp for a calendar.
    func updateSyncToken(calendarId: String, accountId: String, token: String) async throws {
        try await db.dbPool.write { db in
            try MailDatabaseQueries.updateCalendarSyncToken(
                calendarId: calendarId, accountId: accountId, token: token, in: db
            )
        }
    }
}
