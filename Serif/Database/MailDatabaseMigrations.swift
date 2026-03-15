import GRDB

enum MailDatabaseMigrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        registerV1(&migrator)
        registerV2(&migrator)
        registerV3(&migrator)
        registerV4(&migrator)
        return migrator
    }

    private static func registerV1(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            // -- messages --
            try db.create(table: "messages") { t in
                t.primaryKey("gmail_id", .text)
                t.column("thread_id", .text).notNull()
                t.column("history_id", .text)
                t.column("internal_date", .double).notNull()
                t.column("snippet", .text)
                t.column("size_estimate", .integer)
                t.column("subject", .text)
                t.column("sender_email", .text)
                t.column("sender_name", .text)
                t.column("to_recipients", .text)
                t.column("cc_recipients", .text)
                t.column("bcc_recipients", .text)
                t.column("reply_to", .text)
                t.column("message_id_header", .text)
                t.column("in_reply_to", .text)
                t.column("body_html", .text)
                t.column("body_plain", .text)
                t.column("raw_headers", .text)
                t.column("has_attachments", .boolean).notNull().defaults(to: false)
                t.column("is_read", .boolean).notNull().defaults(to: false)
                t.column("is_starred", .boolean).notNull().defaults(to: false)
                t.column("is_from_mailing_list", .boolean).notNull().defaults(to: false)
                t.column("unsubscribe_url", .text)
                t.column("full_body_fetched", .boolean).notNull().defaults(to: false)
                t.column("thread_message_count", .integer).notNull().defaults(to: 1)
                t.column("fetched_at", .double)
            }
            try db.create(index: "messages_thread_id", on: "messages", columns: ["thread_id"])
            try db.create(index: "messages_date", on: "messages", columns: ["internal_date"])
            try db.create(index: "messages_sender", on: "messages", columns: ["sender_email"])
            try db.create(index: "messages_prefetch", on: "messages", columns: ["full_body_fetched", "internal_date"])

            // -- labels --
            try db.create(table: "labels") { t in
                t.primaryKey("gmail_id", .text)
                t.column("name", .text).notNull()
                t.column("type", .text)
                t.column("bg_color", .text)
                t.column("text_color", .text)
            }

            // -- message_labels (join) --
            try db.create(table: "message_labels") { t in
                t.column("message_id", .text).notNull()
                    .references("messages", column: "gmail_id", onDelete: .cascade)
                t.column("label_id", .text).notNull()
                    .references("labels", column: "gmail_id", onDelete: .restrict)
                t.primaryKey(["message_id", "label_id"])
            }
            try db.create(index: "message_labels_label", on: "message_labels", columns: ["label_id"])
            try db.create(index: "message_labels_message", on: "message_labels", columns: ["message_id"])

            // -- contacts --
            try db.create(table: "contacts") { t in
                t.primaryKey("email", .text).collate(.nocase)
                t.column("name", .text)
                t.column("photo_url", .text)
                t.column("source", .text)
                t.column("resource_name", .text)
                t.column("updated_at", .double)
            }

            // -- attachments --
            try db.create(table: "attachments") { t in
                t.primaryKey("id", .text)
                t.column("message_id", .text).notNull()
                    .references("messages", column: "gmail_id", onDelete: .cascade)
                t.column("gmail_attachment_id", .text).notNull()
                t.column("filename", .text)
                t.column("mime_type", .text)
                t.column("file_type", .text)
                t.column("size", .integer)
                t.column("content_id", .text)
                t.column("direction", .text)
                t.column("indexing_status", .text).defaults(to: "pending")
                t.column("extracted_text", .text)
                t.column("indexed_at", .double)
                t.column("retry_count", .integer).defaults(to: 0)
            }
            try db.create(index: "attachments_message", on: "attachments", columns: ["message_id"])
            try db.create(index: "attachments_status", on: "attachments", columns: ["indexing_status"])

            // -- email_tags --
            try db.create(table: "email_tags") { t in
                t.primaryKey("message_id", .text)
                    .references("messages", column: "gmail_id", onDelete: .cascade)
                t.column("needs_reply", .boolean).notNull().defaults(to: false)
                t.column("fyi_only", .boolean).notNull().defaults(to: false)
                t.column("has_deadline", .boolean).notNull().defaults(to: false)
                t.column("financial", .boolean).notNull().defaults(to: false)
                t.column("classified_at", .double)
                t.column("classifier_version", .integer)
            }

            // -- folder_sync_state --
            // Legacy: table exists but is unused; retained for migration compatibility
            try db.create(table: "folder_sync_state") { t in
                t.primaryKey("folder_key", .text)
                t.column("history_id", .text)
                t.column("next_page_token", .text)
                t.column("last_full_sync", .double)
                t.column("last_delta_sync", .double)
            }

            // -- account_sync_state (single row) --
            try db.create(table: "account_sync_state") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("contacts_sync_token", .text)
                t.column("other_contacts_sync_token", .text)
            }
            // Seed the single row (OR IGNORE for idempotency)
            try db.execute(sql: "INSERT OR IGNORE INTO account_sync_state (id) VALUES (1)")

            // -- FTS5 (manual, not content-sync) --
            try db.execute(sql: """
                CREATE VIRTUAL TABLE messages_fts USING fts5(
                    gmail_id UNINDEXED,
                    subject,
                    body_plain,
                    snippet,
                    sender_name,
                    sender_email,
                    tokenize='porter unicode61'
                )
            """)
        }
    }

    private static func registerV2(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_sync_state") { db in
            try db.alter(table: "account_sync_state") { t in
                t.add(column: "last_history_id", .text)
                t.add(column: "initial_sync_complete", .boolean).notNull().defaults(to: false)
                t.add(column: "initial_sync_page_token", .text)
                t.add(column: "total_messages_estimate", .integer)
                t.add(column: "synced_message_count", .integer).notNull().defaults(to: 0)
                t.add(column: "last_sync_at", .double)
                t.add(column: "last_body_prefetch_at", .double)
                t.add(column: "directory_sync_token", .text)
            }
            try db.drop(table: "folder_sync_state")
        }
    }

    private static func registerV3(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3_labels_etag") { db in
            try db.alter(table: "account_sync_state") { t in
                t.add(column: "labels_etag", .text)
            }
        }
    }

    private static func registerV4(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4_unread_index") { db in
            // Partial index for unread message queries (count + sorted listing).
            // Indexed on internal_date so the query planner can use it for
            // both unread counts and date-sorted unread message lists.
            try db.create(
                index: "messages_unread",
                on: "messages",
                columns: ["internal_date"],
                condition: Column("is_read") == false
            )

            // Drop redundant index — composite PK [message_id, label_id]
            // already supports queries filtering by message_id (leftmost column)
            try db.drop(index: "message_labels_message")
        }
    }
}
