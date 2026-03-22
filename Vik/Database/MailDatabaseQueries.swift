import Foundation
internal import GRDB

/// A calendar event record paired with its attendees, fetched in a single query via GRDB association prefetching.
struct EventWithAttendees: Decodable, FetchableRecord, Sendable {
    var calendarEventRecord: CalendarEventRecord
    var attendees: [CalendarAttendeeRecord]
}

/// Centralized read queries for the mail database.
/// All methods take a `Database` parameter and should be called within dbPool.read { }.
enum MailDatabaseQueries {

    /// Messages for a given label, newest first.
    /// Selects only list-display columns — excludes heavy body/header blobs.
    static func messagesForLabel(_ labelId: String, limit: Int = 50, offset: Int = 0, in db: Database) throws -> [MessageRecord] {
        try MessageRecord
            .select(MessageRecord.listColumns)
            .joining(required: MessageRecord.messageLabels
                .filter(Column("label_id") == labelId))
            .order(Column("internal_date").desc)
            .limit(limit, offset: offset)
            .fetchAll(db)
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

    /// All contacts, ordered by name. Pass a limit to cap memory usage for large contact sets.
    static func allContacts(limit: Int? = nil, in db: Database) throws -> [ContactRecord] {
        var request = ContactRecord.order(Column("name").asc)
        if let limit { request = request.limit(limit) }
        return try request.fetchAll(db)
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

    // MARK: - Label Mutation

    /// Rebuild the `message_labels` join rows for a message and sync denormalized columns.
    /// Shared by `MailboxViewModel`, `BackgroundSyncer.applyDelta`, and `BackgroundSyncer.upsertSingleMessage`.
    /// Must be called inside an existing write transaction.
    static func rebuildLabels(
        forMessageID gmailId: String,
        newLabelIDs: [String],
        in db: Database
    ) throws {
        try rebuildLabelsBatch(updates: [(messageId: gmailId, labelIds: newLabelIDs)], in: db)
    }

    /// Batch variant — processes multiple messages in one set of SQL statements.
    /// Prefer this when updating labels for many messages at once.
    static func rebuildLabelsBatch(
        updates: [(messageId: String, labelIds: [String])],
        in db: Database
    ) throws {
        guard !updates.isEmpty else { return }

        // 1. Collect all unique label IDs across all messages.
        let allLabelIds = Set(updates.flatMap { $0.labelIds })

        // 2. Batch-insert all unique LabelRecords (ignore duplicates).
        if !allLabelIds.isEmpty {
            // Build a single multi-row INSERT OR IGNORE for all label stubs.
            let placeholders = allLabelIds.map { _ in "(?, ?, NULL, NULL, NULL)" }.joined(separator: ", ")
            var args: [DatabaseValue] = []
            for labelId in allLabelIds {
                args.append(labelId.databaseValue)
                args.append(labelId.databaseValue)
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO labels (gmail_id, name, type, bg_color, text_color) VALUES \(placeholders)",
                arguments: StatementArguments(args)
            )
        }

        // 3. Delete existing label assignments for all affected messages.
        let messageIds = updates.map { $0.messageId }
        let deletePlaceholders = messageIds.map { _ in "?" }.joined(separator: ", ")
        try db.execute(
            sql: "DELETE FROM message_labels WHERE message_id IN (\(deletePlaceholders))",
            arguments: StatementArguments(messageIds.map { $0.databaseValue })
        )

        // 4. Batch-insert all new message↔label assignments.
        let allAssignments = updates.flatMap { update in
            update.labelIds.map { (messageId: update.messageId, labelId: $0) }
        }
        if !allAssignments.isEmpty {
            let placeholders = allAssignments.map { _ in "(?, ?)" }.joined(separator: ", ")
            var args: [DatabaseValue] = []
            for pair in allAssignments {
                args.append(pair.messageId.databaseValue)
                args.append(pair.labelId.databaseValue)
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO message_labels (message_id, label_id) VALUES \(placeholders)",
                arguments: StatementArguments(args)
            )
        }

        // 5. Update denormalized is_read / is_starred in a single CASE/WHEN statement
        //    instead of one UPDATE per message — O(1) round trips regardless of batch size.
        var readCases = ""
        var starredCases = ""
        var readArgs: [DatabaseValueConvertible] = []
        var starredArgs: [DatabaseValueConvertible] = []
        for update in updates {
            let isRead = !update.labelIds.contains(GmailSystemLabel.unread)
            let isStarred = update.labelIds.contains(GmailSystemLabel.starred)
            readCases += " WHEN ? THEN ?"
            starredCases += " WHEN ? THEN ?"
            readArgs += [update.messageId, isRead]
            starredArgs += [update.messageId, isStarred]
        }
        let inPlaceholders = updates.map { _ in "?" }.joined(separator: ", ")
        let inArgs: [DatabaseValueConvertible] = updates.map { $0.messageId }
        // Argument order matches SQL placeholder order: all read CASE args, then starred CASE args, then IN args.
        try db.execute(
            sql: """
                UPDATE messages SET
                    is_read = CASE gmail_id\(readCases) END,
                    is_starred = CASE gmail_id\(starredCases) END
                WHERE gmail_id IN (\(inPlaceholders))
                """,
            arguments: StatementArguments(readArgs + starredArgs + inArgs)
        )
    }

    // MARK: - Thread Counts

    /// Update `thread_message_count` for all messages belonging to the given threads.
    /// Uses a CTE to compute counts once per thread, avoiding a correlated subquery
    /// that would execute COUNT(*) for every row in the UPDATE's target set.
    static func updateThreadCounts(for threadIDs: Set<String>, in db: Database) throws {
        guard !threadIDs.isEmpty else { return }
        let placeholders = threadIDs.sqlPlaceholders
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

    /// All calendars across every account (for sidebar display — includes hidden ones).
    static func allCalendars(in db: Database) throws -> [CalendarRecord] {
        try CalendarRecord
            .order(Column("is_primary").desc, Column("summary").asc)
            .fetchAll(db)
    }

    // MARK: - Calendar Events

    /// Events within a date range scoped to a single account and a set of calendar IDs.
    /// Used by `NotificationService` where the account is always known.
    static func eventsForDateRange(
        accountId: String,
        calendarIds: [String],
        start: Double,
        end: Double,
        in db: Database
    ) throws -> [CalendarEventRecord] {
        guard !calendarIds.isEmpty else { return [] }
        return try CalendarEventRecord
            .filter(calendarIds.contains(Column("calendar_id")))
            .filter(Column("account_id") == accountId)
            .filter(Column("start_time") < end)
            .filter(Column("end_time") > start)
            .order(Column("start_time").asc)
            .fetchAll(db)
    }

    /// Events within a date range for a unified multi-account view.
    /// Each key pairs a calendar ID with its owning account, preventing cross-account
    /// collisions on shared calendar IDs (e.g. `company-all@group.calendar.google.com`).
    /// Uses a SQL tuple `IN` clause so SQLite can leverage the composite index efficiently.
    static func eventsForDateRange(
        calendarKeys: [(calendarId: String, accountId: String)],
        start: Double,
        end: Double,
        in db: Database
    ) throws -> [CalendarEventRecord] {
        guard !calendarKeys.isEmpty else { return [] }
        let placeholders = calendarKeys.map { _ in "(?, ?)" }.joined(separator: ", ")
        let keyArgs: [any DatabaseValueConvertible] = calendarKeys.flatMap { [$0.calendarId, $0.accountId] as [any DatabaseValueConvertible] }
        return try CalendarEventRecord
            .filter(sql: "(calendar_id, account_id) IN (\(placeholders))", arguments: StatementArguments(keyArgs))
            .filter(Column("start_time") < end)
            .filter(Column("end_time") > start)
            .order(Column("start_time").asc)
            .fetchAll(db)
    }

    /// Events with attendees within a date range for a unified multi-account view.
    /// Uses GRDB association prefetching to fetch events and attendees in a single
    /// database read, eliminating the need for a separate attendee query.
    static func eventsWithAttendeesForDateRange(
        calendarKeys: [(calendarId: String, accountId: String)],
        start: Double,
        end: Double,
        in db: Database
    ) throws -> [EventWithAttendees] {
        guard !calendarKeys.isEmpty else { return [] }
        let placeholders = calendarKeys.map { _ in "(?, ?)" }.joined(separator: ", ")
        let keyArgs: [any DatabaseValueConvertible] = calendarKeys.flatMap { [$0.calendarId, $0.accountId] as [any DatabaseValueConvertible] }
        return try CalendarEventRecord
            .filter(sql: "(calendar_id, account_id) IN (\(placeholders))", arguments: StatementArguments(keyArgs))
            .filter(Column("start_time") < end)
            .filter(Column("end_time") > start)
            .including(all: CalendarEventRecord.attendees)
            .order(Column("start_time").asc)
            .asRequest(of: EventWithAttendees.self)
            .fetchAll(db)
    }

    /// Events for today (midnight to midnight in the system's local time zone), optionally scoped to an account.
    /// Only returns events from visible/selected calendars.
    static func eventsForToday(accountId: String?, in db: Database) throws -> [CalendarEventRecord] {
        let calendar = Calendar(identifier: .gregorian)
        let startOfToday = calendar.startOfDay(for: Date())
        let todayStart = startOfToday.timeIntervalSince1970
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: startOfToday)!.timeIntervalSince1970

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
