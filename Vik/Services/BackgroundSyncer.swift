import Foundation
internal import GRDB

/// Actor responsible for bulk database writes during API sync.
/// Bulk operations (sync, pre-fetch, batch upsert) go through this actor.
/// Lightweight writes (star, read, archive) go directly through dbPool.write.
actor BackgroundSyncer {
    let db: MailDatabase
    private nonisolated(unsafe) static let htmlTagRegex = try! Regex("<[^>]+>")
    private nonisolated(unsafe) static let whitespaceRegex = try! Regex("\\s+")

    /// Strip HTML tags and collapse whitespace using pre-compiled regexes.
    nonisolated private static func stripHTML(_ html: String) -> String {
        html.replacing(Self.htmlTagRegex, with: " ")
            .replacing(Self.whitespaceRegex, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

            // Batch-prefetch existing label sets for all messages in a single query
            // instead of N per-message queries inside upsertSingleMessage.
            let gmailIds = gmailMessages.map(\.id)
            var existingLabelSets: [String: Set<String>] = [:]
            if !gmailIds.isEmpty {
                let placeholders = gmailIds.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql:
                    "SELECT message_id, label_id FROM message_labels WHERE message_id IN (\(placeholders))",
                    arguments: StatementArguments(gmailIds)
                )
                for row in rows {
                    let messageId: String = row["message_id"]
                    let labelId: String = row["label_id"]
                    existingLabelSets[messageId, default: []].insert(labelId)
                }
            }

            var affectedThreadIds = Set<String>()

            for gmail in gmailMessages {
                try Self.upsertSingleMessage(gmail, in: db, affectedThreadIds: &affectedThreadIds, existingLabelSets: existingLabelSets)
            }

            try MailDatabaseQueries.updateThreadCounts(for: affectedThreadIds, in: db)
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
            // FTS cleanup is handled by the AFTER DELETE trigger (v6 migration) — no manual delete needed.
            // CASCADE handles message_labels, email_tags, attachments
            try MessageRecord.deleteAll(db, keys: gmailIds)
            try MailDatabaseQueries.updateThreadCounts(for: affectedThreadIds, in: db)
        }
        // NOTE: GRDB and AttachmentDatabase use separate SQLite connections, so these deletes are
        // not atomic. AttachmentDatabase.deleteMessages is idempotent — stale entries are harmless
        // and cleaned up on next indexer scan.
        await AttachmentDatabase.shared.deleteMessages(gmailIds)
    }

    // MARK: - Draft ID Backfill

    /// Populate `gmail_draft_id` on existing message records.
    /// Called after fetching from the Gmail Drafts API, which returns
    /// `GmailDraft.id` (draft ID) paired with `GmailDraft.message.id` (message ID).
    /// The regular messages API does not include draft IDs.
    func updateDraftIds(_ mappings: [(messageGmailId: String, draftId: String)]) async throws {
        guard !mappings.isEmpty else { return }
        try await db.dbPool.write { db in
            for mapping in mappings {
                try db.execute(
                    sql: "UPDATE messages SET gmail_draft_id = ? WHERE gmail_id = ?",
                    arguments: [mapping.draftId, mapping.messageGmailId]
                )
            }
        }
    }

    // MARK: - Body Pre-fetch Update

    /// Update message bodies after background pre-fetch.
    func updateBodies(_ updates: [(gmailId: String, html: String?, plain: String?)]) async throws {
        guard !updates.isEmpty else { return }
        let prepared = updates.map { update -> (gmailId: String, html: String?, plainText: String?) in
            let plainText: String?
            if let plain = update.plain {
                plainText = plain
            } else if let html = update.html {
                plainText = Self.stripHTML(html)
            } else {
                plainText = nil
            }
            return (gmailId: update.gmailId, html: update.html, plainText: plainText)
        }
        try await db.dbPool.write { db in
            let now = Date().timeIntervalSince1970
            for item in prepared {
                try db.execute(
                    sql: "UPDATE messages SET body_html = ?, body_plain = ?, full_body_fetched = 1, fetched_at = ? WHERE gmail_id = ?",
                    arguments: [item.html, item.plainText, now, item.gmailId]
                )
            }
        }
    }

    /// Increment body fetch attempt counter for messages that failed to fetch.
    func incrementBodyFetchAttempts(for gmailIds: [String]) async throws {
        guard !gmailIds.isEmpty else { return }
        try await db.dbPool.write { db in
            let placeholders = gmailIds.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "UPDATE messages SET body_fetch_attempts = body_fetch_attempts + 1 WHERE gmail_id IN (\(placeholders))",
                arguments: StatementArguments(gmailIds)
            )
        }
    }

    // MARK: - Label Sync

    /// Upsert labels and delete stale ones in a single transaction.
    /// Restricts cascade-deletes to user labels only — system labels are never removed,
    /// preventing `ON DELETE CASCADE` from wiping `message_labels` if the API returns a partial list.
    func syncLabels(_ gmailLabels: [GmailLabel]) async throws {
        guard !gmailLabels.isEmpty else { return }
        let validIDs = Set(gmailLabels.map(\.id))
        try await db.dbPool.write { db in
            for gmail in gmailLabels {
                try LabelRecord(from: gmail).upsert(db)
            }
            // Only delete stale user labels — never cascade-delete system labels
            try LabelRecord
                .filter(!validIDs.contains(Column("gmail_id")))
                .filter(Column("type") == "user")
                .deleteAll(db)
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
                // FTS cleanup is handled by the AFTER DELETE trigger (v6 migration) — no manual delete needed.
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
                    try MessageLabelRecord(messageId: update.gmailId, labelId: labelId).insert(db, onConflict: .ignore)
                }
                // Update denormalized columns
                let isRead = !update.labelIds.contains(GmailSystemLabel.unread)
                let isStarred = update.labelIds.contains(GmailSystemLabel.starred)
                try db.execute(sql: """
                    UPDATE messages SET is_read = ?, is_starred = ? WHERE gmail_id = ?
                """, arguments: [isRead, isStarred, update.gmailId])
            }

            try MailDatabaseQueries.updateThreadCounts(for: affectedThreadIds, in: db)
        }
        if !deletedIds.isEmpty {
            await AttachmentDatabase.shared.deleteMessages(deletedIds)
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

    /// Upsert contacts but preserve existing photo URLs when the incoming value is nil.
    /// Used for Other Contacts which don't carry photo fields — avoids overwriting
    /// photos already stored from Connections.
    func upsertContactsPreservingPhotos(
        _ contacts: [(email: String, name: String?, photoUrl: String?, source: String, resourceName: String?)]
    ) async throws {
        guard !contacts.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try await db.dbPool.write { db in
            for contact in contacts {
                try db.execute(sql: """
                    INSERT INTO contacts (email, name, photo_url, source, resource_name, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(email) DO UPDATE SET
                        name = excluded.name,
                        photo_url = COALESCE(excluded.photo_url, contacts.photo_url),
                        source = excluded.source,
                        resource_name = excluded.resource_name,
                        updated_at = excluded.updated_at
                """, arguments: [
                    contact.email.lowercased(),
                    contact.name,
                    contact.photoUrl,
                    contact.source,
                    contact.resourceName,
                    now,
                ])
            }
        }
    }

    func deleteContacts(emails: [String]) async throws {
        guard !emails.isEmpty else { return }
        _ = try await db.dbPool.write { db in
            try ContactRecord.filter(emails.map { $0.lowercased() }.contains(Column("email"))).deleteAll(db)
        }
    }

    /// Prune contacts sourced from message headers that no longer have corresponding messages.
    func pruneStaleContacts() async throws {
        try await db.dbPool.write { db in
            try MailDatabaseQueries.pruneStaleMessageContacts(in: db)
        }
    }

    // MARK: - Private Helpers

    /// Upsert a single message: record, labels, attachments, FTS.
    /// Checks whether the message already exists and skips unchanged writes to reduce
    /// write amplification (avoids CASCADE deletes of labels/attachments on every sync).
    /// - Parameter existingLabelSets: Pre-fetched label sets keyed by gmail_id. When provided,
    ///   avoids a per-message DB query for label comparison. Pass `nil` to query per-message (fallback).
    private static func upsertSingleMessage(
        _ gmail: GmailMessage,
        in db: Database,
        affectedThreadIds: inout Set<String>,
        existingLabelSets: [String: Set<String>]? = nil
    ) throws {
        let record = MessageRecord(from: gmail)
        let existing = try MessageRecord.fetchOne(db, key: record.gmailId)

        if let existing {
            // --- Existing message: conditional update ---
            // Break into sub-expressions to keep type-checker happy
            let headersChanged: Bool = existing.subject != record.subject
                || existing.snippet != record.snippet
                || existing.senderEmail != record.senderEmail
                || existing.senderName != record.senderName
                || existing.historyId != record.historyId
                || existing.sizeEstimate != record.sizeEstimate
            let fieldsChanged: Bool = existing.toRecipients != record.toRecipients
                || existing.ccRecipients != record.ccRecipients
                || existing.replyTo != record.replyTo
                || existing.messageIdHeader != record.messageIdHeader
                || existing.inReplyTo != record.inReplyTo
                || existing.referencesHeader != record.referencesHeader
            let metaChanged: Bool = existing.hasAttachments != record.hasAttachments
                || existing.isFromMailingList != record.isFromMailingList
                || existing.unsubscribeUrl != record.unsubscribeUrl
            let contentChanged = headersChanged || fieldsChanged || metaChanged

            let bodyChanged: Bool = (record.fullBodyFetched && !existing.fullBodyFetched)
                || (record.bodyHtml != nil && existing.bodyHtml != record.bodyHtml)
                || (record.bodyPlain != nil && existing.bodyPlain != record.bodyPlain)

            // Compare full label set (not just denormalized is_read/is_starred)
            // to catch category changes, custom label adds, archive, etc.
            let existingLabelIds: Set<String>
            if let prefetched = existingLabelSets?[existing.gmailId] {
                existingLabelIds = prefetched
            } else {
                existingLabelIds = try Set(String.fetchAll(db, sql:
                    "SELECT label_id FROM message_labels WHERE message_id = ?",
                    arguments: [existing.gmailId]
                ))
            }
            let newLabelIds = Set(gmail.labelIds ?? [])
            let labelsChanged: Bool = existingLabelIds != newLabelIds

            if contentChanged || bodyChanged || labelsChanged {
                // Preserve body if the new record doesn't have it but the old one does
                var toSave = record
                if !record.fullBodyFetched && existing.fullBodyFetched {
                    toSave.bodyHtml = existing.bodyHtml
                    toSave.bodyPlain = existing.bodyPlain
                    toSave.fullBodyFetched = true
                }
                toSave.fetchedAt = existing.fetchedAt
                // Preserve draft ID — it's backfilled from the Drafts API, not the Messages API.
                toSave.gmailDraftId = existing.gmailDraftId
                // Preserve retry counter — resetting causes infinite retries for unfetchable messages.
                toSave.bodyFetchAttempts = existing.bodyFetchAttempts
                // Preserve thread count — updateThreadCounts only runs for newly-inserted messages.
                toSave.threadMessageCount = existing.threadMessageCount
                try toSave.update(db)

                // FTS is maintained by the AFTER UPDATE trigger (v14+) which covers
                // subject, snippet, body_plain, sender_name, and sender_email.
                // No explicit FTSManager call needed on updates — only on INSERTs below.
            }

            // Only rebuild labels if they changed
            if labelsChanged {
                try rebuildMessageLabels(for: record.gmailId, gmail: gmail, in: db)
            }

            // Attachments and thread counts: not affected by updates to existing messages
        } else {
            // --- New message: full insert ---
            try record.insert(db)
            affectedThreadIds.insert(record.threadId)

            try rebuildMessageLabels(for: record.gmailId, gmail: gmail, in: db)

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
                try attachment.insert(db)
            }

            try FTSManager.update(message: record, in: db)
        }
    }

    /// Rebuild message_labels join rows for a message.
    private static func rebuildMessageLabels(
        for messageId: String,
        gmail: GmailMessage,
        in db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM message_labels WHERE message_id = ?",
            arguments: [messageId]
        )
        for labelId in gmail.labelIds ?? [] {
            try LabelRecord(gmailId: labelId, name: labelId, type: nil, bgColor: nil, textColor: nil)
                .insert(db, onConflict: .ignore)
            try MessageLabelRecord(messageId: messageId, labelId: labelId).insert(db, onConflict: .ignore)
        }
    }

}
