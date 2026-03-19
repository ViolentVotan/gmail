import Foundation
internal import GRDB

/// Centralized FTS5 index maintenance for the messages_fts virtual table.
/// All code paths that modify searchable columns on messages MUST go through this.
/// FTS5 does not support INSERT OR REPLACE — all updates use DELETE + INSERT.
enum FTSManager {

    /// Index a new message into FTS. Call inside a write transaction.
    /// Deletes any existing entry first so the operation is idempotent.
    static func index(message: MessageRecord, in db: Database) throws {
        try delete(gmailId: message.gmailId, in: db)
        try db.execute(
            sql: """
                INSERT INTO messages_fts(gmail_id, subject, body_plain, snippet, sender_name, sender_email)
                VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [message.gmailId, message.subject, message.bodyPlain, message.snippet, message.senderName, message.senderEmail]
        )
    }

    /// Update an existing message's FTS entry. Delegates to `index`, which handles
    /// DELETE + INSERT internally — no extra delete needed here.
    static func update(message: MessageRecord, in db: Database) throws {
        try index(message: message, in: db)
    }

    /// Remove a message from the FTS index.
    static func delete(gmailId: String, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM messages_fts WHERE gmail_id = ?",
            arguments: [gmailId]
        )
    }

}
