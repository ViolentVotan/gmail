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

    /// Evict body content but keep subject/snippet/sender searchable.
    static func evictBody(gmailId: String, subject: String?, snippet: String?, senderName: String?, senderEmail: String?, in db: Database) throws {
        try db.execute(sql: "DELETE FROM messages_fts WHERE gmail_id = ?", arguments: [gmailId])
        try db.execute(
            sql: """
                INSERT INTO messages_fts(gmail_id, subject, body_plain, snippet, sender_name, sender_email)
                VALUES (?, ?, NULL, ?, ?, ?)
            """,
            arguments: [gmailId, subject, snippet, senderName, senderEmail]
        )
    }

    /// Batch index multiple messages. Call inside a write transaction.
    static func indexBatch(_ messages: [MessageRecord], in db: Database) throws {
        for message in messages {
            try index(message: message, in: db)
        }
    }

    /// Search messages by query string. Returns matching MessageRecords ordered by relevance.
    static func search(query: String, in db: Database, limit: Int = 100) throws -> [MessageRecord] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        // Build FTS5 query — match all tokens
        guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }

        return try MessageRecord.fetchAll(db, sql: """
            SELECT m.* FROM messages m
            WHERE m.gmail_id IN (
                SELECT gmail_id FROM messages_fts WHERE messages_fts MATCH ?
            )
            ORDER BY m.internal_date DESC
            LIMIT ?
        """, arguments: [pattern, limit])
    }
}
