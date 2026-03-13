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

    /// All labels for the account.
    static func allLabels(in db: Database) throws -> [LabelRecord] {
        try LabelRecord.order(Column("name")).fetchAll(db)
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

    /// Batch check which gmail IDs are NOT in the database.
    /// Processes in chunks of 500 to stay within SQLite's variable limit.
    static func missingMessageIds(from ids: [String], in db: Database) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let chunkSize = 500
        var existingSet = Set<String>()
        for chunkStart in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, ids.count)
            let chunk = Array(ids[chunkStart..<chunkEnd])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let found = try String.fetchAll(db, sql: """
                SELECT gmail_id FROM messages WHERE gmail_id IN (\(placeholders))
            """, arguments: StatementArguments(chunk))
            existingSet.formUnion(found)
        }
        return ids.filter { !existingSet.contains($0) }
    }

    /// Contact photo URL for an email address.
    static func contactPhotoUrl(forEmail email: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT photo_url FROM contacts WHERE email = ? COLLATE NOCASE
        """, arguments: [email])
    }
}
