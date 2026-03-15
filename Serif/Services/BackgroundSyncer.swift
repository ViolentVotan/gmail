import Foundation
import GRDB

/// Actor responsible for bulk database writes during API sync.
/// Bulk operations (sync, pre-fetch, batch upsert) go through this actor.
/// Lightweight writes (star, read, archive) go directly through dbPool.write.
actor BackgroundSyncer {
    let db: MailDatabase

    init(db: MailDatabase) {
        self.db = db
    }

    // MARK: - Message Upsert

    /// Upsert messages from API response into database.
    /// Handles: message records, label records, message_labels join, FTS index, thread counts.
    func upsertMessages(_ gmailMessages: [GmailMessage], ensureLabels labelIds: [String]) async throws {
        guard !gmailMessages.isEmpty else { return }
        try await db.dbPool.write { db in
            // Ensure label records exist (insert placeholder only if absent — preserves synced metadata)
            for labelId in labelIds {
                let label = LabelRecord(gmailId: labelId, name: labelId, type: "system", bgColor: nil, textColor: nil)
                try label.insert(db, onConflict: .ignore)
            }

            var affectedThreadIds = Set<String>()

            for gmail in gmailMessages {
                try Self.upsertSingleMessage(gmail, in: db, affectedThreadIds: &affectedThreadIds)
            }

            try Self.updateThreadCounts(for: affectedThreadIds, in: db)
        }
    }

    // MARK: - Message Deletion

    /// Remove messages from database (e.g., from history delta).
    func deleteMessages(gmailIds: [String]) async throws {
        guard !gmailIds.isEmpty else { return }
        try await db.dbPool.write { db in
            // Collect thread IDs before deletion so we can update counts afterward
            let placeholders = gmailIds.map { _ in "?" }.joined(separator: ",")
            let affectedThreadIds = try Set(String.fetchAll(db, sql:
                "SELECT DISTINCT thread_id FROM messages WHERE gmail_id IN (\(placeholders))",
                arguments: StatementArguments(gmailIds)
            ))
            for id in gmailIds {
                try FTSManager.delete(gmailId: id, in: db)
            }
            // CASCADE handles message_labels, email_tags, attachments
            try MessageRecord.deleteAll(db, keys: gmailIds)
            try Self.updateThreadCounts(for: affectedThreadIds, in: db)
        }
    }

    // MARK: - Body Pre-fetch Update

    /// Update message bodies after background pre-fetch.
    func updateBodies(_ updates: [(gmailId: String, html: String?, plain: String?)]) async throws {
        guard !updates.isEmpty else { return }
        try await db.dbPool.write { db in
            let now = Date().timeIntervalSince1970
            for update in updates {
                // Fetch record once; use it for both the DB update and FTS — no second read needed.
                guard var record = try MessageRecord.fetchOne(db, key: update.gmailId) else { continue }
                record.bodyHtml = update.html
                record.bodyPlain = update.plain
                record.fullBodyFetched = true
                record.fetchedAt = now
                try record.update(db)
                try FTSManager.update(message: record, in: db)
            }
        }
    }

    // MARK: - Label Sync

    /// Upsert labels from API.
    func upsertLabels(_ gmailLabels: [GmailLabel]) async throws {
        guard !gmailLabels.isEmpty else { return }
        try await db.dbPool.write { db in
            for gmail in gmailLabels {
                try LabelRecord(from: gmail).upsert(db)
            }
        }
    }

    // MARK: - History Delta Sync

    /// Apply history delta: insert new, delete removed, update labels.
    func applyDelta(
        newMessages: [GmailMessage],
        deletedIds: [String],
        labelUpdates: [(gmailId: String, labelIds: [String])]
    ) async throws {
        try await db.dbPool.write { db in
            var affectedThreadIds = Set<String>()

            // Delete removed messages — collect thread IDs before deletion
            if !deletedIds.isEmpty {
                let deletedRecords = try MessageRecord.fetchAll(db, keys: deletedIds)
                for record in deletedRecords {
                    affectedThreadIds.insert(record.threadId)
                }
                for id in deletedIds {
                    try FTSManager.delete(gmailId: id, in: db)
                }
                try MessageRecord.deleteAll(db, keys: deletedIds)
            }

            // Insert new messages
            for gmail in newMessages {
                try Self.upsertSingleMessage(gmail, in: db, affectedThreadIds: &affectedThreadIds)
            }

            // Update labels on existing messages
            // NOTE: Label updates only modify is_read/is_starred and message_labels rows.
            // FTS index is NOT updated here because no searchable fields (subject, body, sender)
            // change during label-only operations. If the interface changes to pass updated
            // content through label updates, FTS must be updated too.
            for update in labelUpdates {
                try db.execute(sql: "DELETE FROM message_labels WHERE message_id = ?", arguments: [update.gmailId])
                for labelId in update.labelIds {
                    try LabelRecord(gmailId: labelId, name: labelId, type: nil, bgColor: nil, textColor: nil).insert(db, onConflict: .ignore)
                    try MessageLabelRecord(messageId: update.gmailId, labelId: labelId).insert(db)
                }
                // Update denormalized columns
                let isRead = !update.labelIds.contains(GmailSystemLabel.unread)
                let isStarred = update.labelIds.contains(GmailSystemLabel.starred)
                try db.execute(sql: """
                    UPDATE messages SET is_read = ?, is_starred = ? WHERE gmail_id = ?
                """, arguments: [isRead, isStarred, update.gmailId])
            }

            try Self.updateThreadCounts(for: affectedThreadIds, in: db)
        }
    }

    // MARK: - Contact Sync

    func upsertContacts(_ contacts: [(email: String, name: String?, photoUrl: String?, source: String, resourceName: String?)]) async throws {
        guard !contacts.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try await db.dbPool.write { db in
            for contact in contacts {
                try ContactRecord(
                    email: contact.email.lowercased(),
                    name: contact.name,
                    photoUrl: contact.photoUrl,
                    source: contact.source,
                    resourceName: contact.resourceName,
                    updatedAt: now
                ).upsert(db)
            }
        }
    }

    func deleteContacts(emails: [String]) async throws {
        guard !emails.isEmpty else { return }
        _ = try await db.dbPool.write { db in
            try ContactRecord.filter(emails.map { $0.lowercased() }.contains(Column("email"))).deleteAll(db)
        }
    }

    // MARK: - Private Helpers

    /// Upsert a single message: record, labels, attachments, FTS.
    /// Uses `FTSManager.update` unconditionally (DELETE + INSERT) to avoid FTS5 duplicate rows
    /// when the same gmailId appears multiple times in a batch.
    private static func upsertSingleMessage(
        _ gmail: GmailMessage,
        in db: Database,
        affectedThreadIds: inout Set<String>
    ) throws {
        let record = MessageRecord(from: gmail)
        try record.upsert(db)
        affectedThreadIds.insert(record.threadId)

        // Replace message_labels for this message
        try db.execute(
            sql: "DELETE FROM message_labels WHERE message_id = ?",
            arguments: [record.gmailId]
        )
        for labelId in gmail.labelIds ?? [] {
            try LabelRecord(gmailId: labelId, name: labelId, type: nil, bgColor: nil, textColor: nil)
                .insert(db, onConflict: .ignore)
            try MessageLabelRecord(messageId: record.gmailId, labelId: labelId).insert(db)
        }

        // Attachments: replace existing records for this message
        try db.execute(
            sql: "DELETE FROM attachments WHERE message_id = ?",
            arguments: [record.gmailId]
        )
        for part in gmail.attachmentParts {
            guard let attachmentId = part.body?.attachmentId else { continue }
            let attachment = AttachmentRecord(
                id: "\(record.gmailId)_\(attachmentId)",
                messageId: record.gmailId,
                gmailAttachmentId: attachmentId,
                filename: part.filename,
                mimeType: part.mimeType,
                fileType: part.filename.map { ($0 as NSString).pathExtension },
                size: part.body?.size,
                contentId: part.contentID,
                direction: nil,
                indexingStatus: "pending",
                extractedText: nil,
                indexedAt: nil,
                retryCount: 0
            )
            try attachment.upsert(db)
        }

        // FTS: always use update (DELETE + INSERT) — safe for new rows since DELETE on
        // non-existent FTS row is a no-op, and avoids duplicates from batch duplicates.
        try FTSManager.update(message: record, in: db)
    }

    /// Update thread_message_count for all messages belonging to the given threads.
    private static func updateThreadCounts(for threadIds: Set<String>, in db: Database) throws {
        guard !threadIds.isEmpty else { return }
        let placeholders = threadIds.map { _ in "?" }.joined(separator: ",")
        try db.execute(sql: """
            UPDATE messages SET thread_message_count = (
                SELECT COUNT(*) FROM messages m2 WHERE m2.thread_id = messages.thread_id
            ) WHERE thread_id IN (\(placeholders))
        """, arguments: StatementArguments(Array(threadIds)))
    }

}
