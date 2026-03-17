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
            DELETE FROM contacts
            WHERE source = 'message'
            AND email NOT IN (SELECT DISTINCT sender_email FROM messages WHERE sender_email IS NOT NULL)
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

}
