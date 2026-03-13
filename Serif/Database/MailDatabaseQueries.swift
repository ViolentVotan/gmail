import Foundation
import GRDB

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
    static func messagesNeedingBodies(limit: Int = 50, in db: Database) throws -> [MessageRecord] {
        try MessageRecord
            .filter(Column("full_body_fetched") == false)
            .order(Column("internal_date").desc)
            .limit(limit)
            .fetchAll(db)
    }

    /// Check if a message exists in the database.
    static func messageExists(_ gmailId: String, in db: Database) throws -> Bool {
        try MessageRecord.fetchOne(db, key: gmailId) != nil
    }

    // MARK: - Contacts

    /// All contacts, ordered by name.
    static func allContacts(in db: Database) throws -> [ContactRecord] {
        try ContactRecord.order(Column("name").asc).fetchAll(db)
    }

    /// Total number of contacts.
    static func contactCount(in db: Database) throws -> Int {
        try ContactRecord.fetchCount(db)
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

}
