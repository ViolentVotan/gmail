import Foundation
internal import GRDB

/// Centralized read queries for the mail database.
/// All methods take a `Database` parameter and should be called within dbPool.read { }.
enum MailDatabaseQueries {

    /// Messages for a given label, newest first.
    static func messagesForLabel(_ labelId: String, limit: Int = 50, offset: Int = 0, in db: Database) throws -> [MessageRecord] {
        try MessageRecord.fetchAll(db, sql: """
            SELECT m.* FROM messages m
            JOIN message_labels ml ON ml.message_id = m.gmail_id
            WHERE ml.label_id = ?
            ORDER BY m.internal_date DESC
            LIMIT ? OFFSET ?
        """, arguments: [labelId, limit, offset])
    }

    /// All messages in a thread, oldest first (for conversation display).
    static func messagesForThread(_ threadId: String, in db: Database) throws -> [MessageRecord] {
        try MessageRecord
            .filter(Column("thread_id") == threadId)
            .order(Column("internal_date").asc)
            .fetchAll(db)
    }

    /// Unread message count for a label.
    static func unreadCount(forLabel labelId: String, in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM messages m
            JOIN message_labels ml ON ml.message_id = m.gmail_id
            WHERE ml.label_id = ? AND m.is_read = 0
        """, arguments: [labelId]) ?? 0
    }

    /// All labels for a message.
    static func labels(forMessage gmailId: String, in db: Database) throws -> [LabelRecord] {
        try LabelRecord.fetchAll(db, sql: """
            SELECT l.* FROM labels l
            JOIN message_labels ml ON ml.label_id = l.gmail_id
            WHERE ml.message_id = ?
        """, arguments: [gmailId])
    }

    /// Messages needing body pre-fetch, newest first.
    /// Excludes messages in Spam or Trash to avoid unnecessary API calls.
    static func messagesNeedingBodies(limit: Int = 50, in db: Database) throws -> [MessageRecord] {
        try MessageRecord.fetchAll(db, sql: """
            SELECT m.* FROM messages m
            WHERE m.full_body_fetched = 0
            AND m.body_fetch_attempts < 3
            AND NOT EXISTS (
                SELECT 1 FROM message_labels ml
                WHERE ml.message_id = m.gmail_id
                AND ml.label_id IN (?, ?)
            )
            ORDER BY m.internal_date DESC
            LIMIT ?
        """, arguments: [GmailSystemLabel.spam, GmailSystemLabel.trash, limit])
    }

    /// Check if a message exists in the database.
    static func messageExists(_ gmailId: String, in db: Database) throws -> Bool {
        try MessageRecord.exists(db, key: gmailId)
    }

    // MARK: - Contacts

    /// All contacts, ordered by name.
    static func allContacts(in db: Database) throws -> [ContactRecord] {
        try ContactRecord.order(Column("name").asc).fetchAll(db)
    }

    /// Deletes contacts sourced from message headers that have no corresponding messages.
    static func pruneStaleMessageContacts(in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM contacts WHERE source = 'message'
            AND NOT EXISTS (SELECT 1 FROM messages WHERE messages.sender_email = contacts.email)
        """)
    }

    // MARK: - Account Sync State

    /// Read the single-row account sync state.
    static func syncState(in db: Database) throws -> AccountSyncStateRecord? {
        try AccountSyncStateRecord.fetchOne(db, key: 1)
    }

    /// Update the single-row account sync state, creating it if it doesn't exist.
    static func updateSyncState(_ update: (inout AccountSyncStateRecord) -> Void, in db: Database) throws {
        var record = try AccountSyncStateRecord.fetchOne(db, key: 1) ?? AccountSyncStateRecord()
        update(&record)
        try record.upsert(db)
    }

    /// Count of messages without bodies (for body pre-fetch progress).
    /// Excludes spam/trash and messages that exceeded retry limit.
    static func messagesWithoutBodiesCount(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM messages m
            WHERE m.full_body_fetched = 0
            AND m.body_fetch_attempts < 3
            AND NOT EXISTS (
                SELECT 1 FROM message_labels ml
                WHERE ml.message_id = m.gmail_id
                AND ml.label_id IN (?, ?)
            )
        """, arguments: [GmailSystemLabel.spam, GmailSystemLabel.trash]) ?? 0
    }

    /// Count of messages associated with a given label.
    static func messageCountForLabel(_ labelId: String, in db: Database) throws -> Int {
        try Int.fetchOne(db, sql:
            "SELECT COUNT(*) FROM message_labels WHERE label_id = ?",
            arguments: [labelId]
        ) ?? 0
    }

    // MARK: - Thread Counts

    /// Update `thread_message_count` for all messages belonging to the given threads.
    /// Uses a CTE to compute counts once per thread, avoiding a correlated subquery
    /// that would execute COUNT(*) for every row in the UPDATE's target set.
    static func updateThreadCounts(for threadIDs: Set<String>, in db: Database) throws {
        guard !threadIDs.isEmpty else { return }
        let placeholders = threadIDs.map { _ in "?" }.joined(separator: ",")
        let args = Array(threadIDs)
        try db.execute(sql: """
            WITH thread_counts AS (
                SELECT thread_id, COUNT(*) AS cnt
                FROM messages
                WHERE thread_id IN (\(placeholders))
                GROUP BY thread_id
            )
            UPDATE messages SET thread_message_count = (
                SELECT cnt FROM thread_counts tc WHERE tc.thread_id = messages.thread_id
            ) WHERE thread_id IN (\(placeholders))
        """, arguments: StatementArguments(args + args))
    }

    // MARK: - Calendars

    /// All calendars for an account.
    static func calendars(accountId: String, in db: Database) throws -> [CalendarRecord] {
        try CalendarRecord
            .filter(Column("account_id") == accountId)
            .order(Column("is_primary").desc, Column("summary").asc)
            .fetchAll(db)
    }

    /// Visible calendars for an account (isVisible == true).
    static func visibleCalendars(accountId: String, in db: Database) throws -> [CalendarRecord] {
        try CalendarRecord
            .filter(Column("account_id") == accountId)
            .filter(Column("is_visible") == true)
            .order(Column("is_primary").desc, Column("summary").asc)
            .fetchAll(db)
    }

    /// All visible calendars across every account (for unified calendar view).
    static func allVisibleCalendars(in db: Database) throws -> [CalendarRecord] {
        try CalendarRecord
            .filter(Column("is_visible") == true)
            .order(Column("is_primary").desc, Column("summary").asc)
            .fetchAll(db)
    }

    // MARK: - Calendar Events

    /// Events within a date range, optionally scoped to an account.
    /// When `accountId` is nil, returns events across all accounts (unified view).
    static func eventsForDateRange(
        accountId: String?,
        calendarIds: [String],
        start: Double,
        end: Double,
        in db: Database
    ) throws -> [CalendarEventRecord] {
        guard !calendarIds.isEmpty else { return [] }
        var request = CalendarEventRecord
            .filter(calendarIds.contains(Column("calendar_id")))
            .filter(Column("start_time") < end)
            .filter(Column("end_time") > start)
        if let accountId {
            request = request.filter(Column("account_id") == accountId)
        }
        return try request
            .order(Column("start_time").asc)
            .fetchAll(db)
    }

    /// Events for today (midnight to midnight UTC), optionally scoped to an account.
    /// Only returns events from visible/selected calendars.
    static func eventsForToday(accountId: String?, in db: Database) throws -> [CalendarEventRecord] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date()).timeIntervalSince1970
        let todayEnd = todayStart + 86400

        var sql = """
            SELECT ce.* FROM calendar_events ce
            JOIN calendars c ON c.calendar_id = ce.calendar_id AND c.account_id = ce.account_id
            WHERE c.is_visible = 1
            AND ce.start_time < ?
            AND ce.end_time > ?
            """
        var args: [any DatabaseValueConvertible] = [todayEnd, todayStart]
        if let accountId {
            sql += "\nAND ce.account_id = ?"
            args.append(accountId)
        }
        sql += "\nORDER BY ce.start_time ASC"
        return try CalendarEventRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    /// Fetches a single event with its attendees. Returns nil if the event is not found.
    static func eventWithAttendees(
        eventId: String,
        calendarId: String,
        accountId: String,
        in db: Database
    ) throws -> (CalendarEventRecord, [CalendarAttendeeRecord])? {
        guard let event = try CalendarEventRecord
            .filter(Column("event_id") == eventId)
            .filter(Column("calendar_id") == calendarId)
            .filter(Column("account_id") == accountId)
            .fetchOne(db) else {
            return nil
        }
        let attendees = try CalendarAttendeeRecord
            .filter(Column("event_id") == eventId)
            .filter(Column("calendar_id") == calendarId)
            .filter(Column("account_id") == accountId)
            .fetchAll(db)
        return (event, attendees)
    }

    /// Upcoming events that include a specific participant (by email), newest first.
    static func upcomingEventsWithParticipant(
        email: String,
        accountId: String,
        limit: Int,
        in db: Database
    ) throws -> [CalendarEventRecord] {
        let now = Date().timeIntervalSince1970
        return try CalendarEventRecord.fetchAll(db, sql: """
            SELECT ce.* FROM calendar_events ce
            JOIN calendar_attendees ca
                ON ca.event_id = ce.event_id
                AND ca.calendar_id = ce.calendar_id
                AND ca.account_id = ce.account_id
            WHERE ca.email = ?
            AND ce.account_id = ?
            AND ce.start_time > ?
            ORDER BY ce.start_time ASC
            LIMIT ?
        """, arguments: [email, accountId, now, limit])
    }

    /// Toggle calendar visibility.
    static func updateCalendarVisibility(
        calendarId: String,
        accountId: String,
        isVisible: Bool,
        in db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE calendars SET is_visible = ? WHERE calendar_id = ? AND account_id = ?",
            arguments: [isVisible, calendarId, accountId]
        )
    }

    /// Read the sync token for a calendar.
    static func calendarSyncToken(
        calendarId: String,
        accountId: String,
        in db: Database
    ) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT sync_token FROM calendars WHERE calendar_id = ? AND account_id = ?",
            arguments: [calendarId, accountId]
        )
    }

    /// Update the sync token for a calendar.
    static func updateCalendarSyncToken(
        calendarId: String,
        accountId: String,
        token: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE calendars SET sync_token = ?, last_synced_at = ? WHERE calendar_id = ? AND account_id = ?",
            arguments: [token, Date().timeIntervalSince1970, calendarId, accountId]
        )
    }

}
