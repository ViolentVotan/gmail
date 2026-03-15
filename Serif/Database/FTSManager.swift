import Foundation
import GRDB

/// Centralized FTS5 index maintenance for the messages_fts virtual table.
/// All code paths that modify searchable columns on messages MUST go through this.
/// FTS5 does not support INSERT OR REPLACE — all updates use DELETE + INSERT.
enum FTSManager {

    /// Index a new message into FTS. Call inside a write transaction.
    static func index(message: MessageRecord, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO messages_fts(gmail_id, subject, body_plain, snippet, sender_name, sender_email)
                VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [message.gmailId, message.subject, message.bodyPlain, message.snippet, message.senderName, message.senderEmail]
        )
    }

    /// Update an existing message's FTS entry. DELETE old + INSERT new.
    static func update(message: MessageRecord, in db: Database) throws {
        try delete(gmailId: message.gmailId, in: db)
        try index(message: message, in: db)
    }

    /// Remove a message from the FTS index.
    static func delete(gmailId: String, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM messages_fts WHERE gmail_id = ?",
            arguments: [gmailId]
        )
    }

    /// Search messages by query string. Returns matching MessageRecords ordered by relevance.
    static func search(query: String, in db: Database, limit: Int = 100) throws -> [MessageRecord] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        // Build FTS5 query — match all tokens
        guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }

        return try MessageRecord.fetchAll(db, sql: """
            SELECT m.* FROM messages m
            JOIN messages_fts f ON f.gmail_id = m.gmail_id
            WHERE f.messages_fts MATCH ?
            ORDER BY m.internal_date DESC
            LIMIT ?
        """, arguments: [pattern, limit])
    }
}
