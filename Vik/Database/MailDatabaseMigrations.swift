internal import GRDB

enum MailDatabaseMigrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Database is preserved across schema changes in all builds.
        // Use Settings → Advanced → "Delete Local Database" to reset during development.
        registerV1(&migrator)
        registerV2(&migrator)
        registerV3(&migrator)
        registerV4(&migrator)
        registerV5(&migrator)
        registerV6(&migrator)
        registerV7(&migrator)
        registerV8(&migrator)
        registerV9(&migrator)
        registerV10(&migrator)
        registerV11(&migrator)
        registerV12(&migrator)
        registerV13(&migrator)
        registerV14(&migrator)
        registerV15(&migrator)
        registerV16(&migrator)
        registerV17(&migrator)
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

    private static func registerV5(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5_cascade_and_not_null") { db in
            // -- Fix 1: Recreate message_labels with onDelete: .cascade on label FK --
            // SQLite doesn't support ALTER COLUMN, so we must recreate the table.
            // GRDB's default migration mode disables FK enforcement during the migration
            // and runs checkForeignKeys() automatically afterward.

            // Clean up any orphan rows before the table swap
            try db.execute(sql: """
                DELETE FROM message_labels
                WHERE message_id NOT IN (SELECT gmail_id FROM messages)
                   OR label_id NOT IN (SELECT gmail_id FROM labels)
            """)

            try db.create(table: "message_labels_new") { t in
                t.column("message_id", .text).notNull()
                    .references("messages", column: "gmail_id", onDelete: .cascade)
                t.column("label_id", .text).notNull()
                    .references("labels", column: "gmail_id", onDelete: .cascade)
                t.primaryKey(["message_id", "label_id"])
            }

            try db.execute(sql: """
                INSERT INTO message_labels_new (message_id, label_id)
                SELECT message_id, label_id FROM message_labels
            """)

            try db.drop(table: "message_labels")
            try db.rename(table: "message_labels_new", to: "message_labels")

            // Recreate the label index (the PK covers message_id lookups)
            try db.create(index: "message_labels_label", on: "message_labels", columns: ["label_id"])

            // -- Fix 2: Add NOT NULL to attachments.indexing_status and retry_count --
            // Backfill any NULLs before the constraint change
            try db.execute(sql: "UPDATE attachments SET indexing_status = 'pending' WHERE indexing_status IS NULL")
            try db.execute(sql: "UPDATE attachments SET retry_count = 0 WHERE retry_count IS NULL")

            try db.create(table: "attachments_new") { t in
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
                t.column("indexing_status", .text).notNull().defaults(to: "pending")
                t.column("extracted_text", .text)
                t.column("indexed_at", .double)
                t.column("retry_count", .integer).notNull().defaults(to: 0)
            }

            try db.execute(sql: """
                INSERT INTO attachments_new
                    (id, message_id, gmail_attachment_id, filename, mime_type,
                     file_type, size, content_id, direction, indexing_status,
                     extracted_text, indexed_at, retry_count)
                SELECT id, message_id, gmail_attachment_id, filename, mime_type,
                       file_type, size, content_id, direction,
                       COALESCE(indexing_status, 'pending'),
                       extracted_text, indexed_at,
                       COALESCE(retry_count, 0)
                FROM attachments
            """)

            try db.drop(table: "attachments")
            try db.rename(table: "attachments_new", to: "attachments")

            // Recreate indexes
            try db.create(index: "attachments_message", on: "attachments", columns: ["message_id"])
            try db.create(index: "attachments_status", on: "attachments", columns: ["indexing_status"])
        }
    }

    private static func registerV6(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6_fts_cascade_trigger") { db in
            // When messages are deleted via CASCADE, the FTS virtual table is not
            // automatically cleaned up. This trigger ensures FTS rows are removed
            // whenever a message is deleted, preventing orphaned FTS entries.
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_fts_delete
                AFTER DELETE ON messages
                BEGIN
                    DELETE FROM messages_fts WHERE gmail_id = OLD.gmail_id;
                END
            """)
        }
    }

    private static func registerV7(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7_fts_update_trigger") { db in
            // Keep FTS index in sync when searchable columns are updated via raw SQL.
            // BackgroundSyncer already calls FTSManager, but this trigger provides
            // defense-in-depth against any future code path that updates these columns directly.
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_fts_update
                AFTER UPDATE OF subject, body_plain, snippet, sender_name, sender_email ON messages
                BEGIN
                    DELETE FROM messages_fts WHERE gmail_id = OLD.gmail_id;
                    INSERT INTO messages_fts(gmail_id, subject, body_plain, snippet, sender_name, sender_email)
                    VALUES (NEW.gmail_id, NEW.subject, NEW.body_plain, NEW.snippet, NEW.sender_name, NEW.sender_email);
                END
            """)
        }
    }

    private static func registerV8(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8_references_header") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "references_header", .text)
            }
        }
    }

    private static func registerV9(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9_sync_token_timestamps") { db in
            try db.alter(table: "account_sync_state") { t in
                t.add(column: "contacts_sync_token_at", .double)
                t.add(column: "other_contacts_sync_token_at", .double)
            }
        }
    }

    private static func registerV10(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v10_indexes_and_draft_id") { db in
            // Composite index for unread count queries joining messages to labels
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS messages_read_state ON messages(gmail_id, is_read)")
            // Composite index for category-scoped unread counts via message_labels
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS message_labels_label_message ON message_labels(label_id, message_id)")
            // Draft resource ID (distinct from gmail_id message ID)
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN gmail_draft_id TEXT")
        }
    }

    private static func registerV11(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v11") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_fts_update")
            try db.drop(index: "message_labels_label")
        }
    }

    private static func registerV12(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v12_body_fetch_attempts") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "body_fetch_attempts", .integer).notNull().defaults(to: 0)
            }
        }
    }

    private static func registerV13(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v13_calendar_tables") { db in
            // Calendars — composite PK (calendar_id, account_id) because "primary" repeats across accounts
            try db.create(table: "calendars") { t in
                t.column("calendar_id", .text).notNull()
                t.column("account_id", .text).notNull()
                t.primaryKey(["calendar_id", "account_id"])
                t.column("summary", .text).notNull()
                t.column("description", .text)
                t.column("time_zone", .text)
                t.column("background_color", .text).notNull().defaults(to: "#3A6FF0")
                t.column("foreground_color", .text).notNull().defaults(to: "#FFFFFF")
                t.column("is_primary", .boolean).notNull().defaults(to: false)
                t.column("access_role", .text).notNull().defaults(to: "reader")
                t.column("is_visible", .boolean).notNull().defaults(to: true)
                t.column("summary_override", .text)
                t.column("sync_token", .text)
                t.column("last_synced_at", .double)
            }
            try db.create(index: "idx_calendars_account", on: "calendars", columns: ["account_id"])

            // Events — composite PK (event_id, calendar_id, account_id)
            try db.create(table: "calendar_events") { t in
                t.column("event_id", .text).notNull()
                t.column("calendar_id", .text).notNull()
                t.column("account_id", .text).notNull()
                t.primaryKey(["event_id", "calendar_id", "account_id"])
                t.foreignKey(["calendar_id", "account_id"], references: "calendars", columns: ["calendar_id", "account_id"], onDelete: .cascade)
                t.column("summary", .text)
                t.column("description", .text)
                t.column("location", .text)
                t.column("start_time", .double).notNull()
                t.column("end_time", .double).notNull()
                t.column("is_all_day", .boolean).notNull().defaults(to: false)
                t.column("time_zone", .text)
                t.column("status", .text).notNull().defaults(to: "confirmed")
                t.column("organizer_email", .text)
                t.column("organizer_name", .text)
                t.column("organizer_is_self", .boolean).notNull().defaults(to: false)
                t.column("creator_email", .text)
                t.column("self_response_status", .text)
                t.column("color_id", .text)
                t.column("is_recurring", .boolean).notNull().defaults(to: false)
                t.column("recurring_event_id", .text)
                t.column("conference_link", .text)
                t.column("conference_name", .text)
                t.column("event_type", .text).notNull().defaults(to: "default")
                t.column("etag", .text).notNull()
                t.column("html_link", .text)
                t.column("can_edit", .boolean).notNull().defaults(to: false)
                t.column("i_cal_uid", .text)
                t.column("sequence", .integer)
                t.column("reminders_json", .text)
                t.column("attachments_json", .text)
                t.column("extended_properties_json", .text)
                t.column("updated_at", .double).notNull()
            }
            try db.create(index: "idx_events_calendar", on: "calendar_events", columns: ["calendar_id", "account_id"])
            try db.create(index: "idx_events_time", on: "calendar_events", columns: ["start_time", "end_time"])
            try db.create(index: "idx_events_account_time", on: "calendar_events", columns: ["account_id", "start_time", "end_time"])
            try db.create(index: "idx_events_recurring", on: "calendar_events", columns: ["recurring_event_id"])
            try db.create(index: "idx_events_ical_uid", on: "calendar_events", columns: ["i_cal_uid"])

            // Attendees — FK to events composite PK
            try db.create(table: "calendar_attendees") { t in
                t.column("event_id", .text).notNull()
                t.column("calendar_id", .text).notNull()
                t.column("account_id", .text).notNull()
                t.column("email", .text).notNull()
                t.column("display_name", .text)
                t.column("response_status", .text).notNull().defaults(to: "needsAction")
                t.column("is_organizer", .boolean).notNull().defaults(to: false)
                t.column("is_resource", .boolean).notNull().defaults(to: false)
                t.column("is_optional", .boolean).notNull().defaults(to: false)
                t.primaryKey(["event_id", "calendar_id", "account_id", "email"])
                t.foreignKey(["event_id", "calendar_id", "account_id"], references: "calendar_events", columns: ["event_id", "calendar_id", "account_id"], onDelete: .cascade)
            }
            try db.create(index: "idx_attendees_email", on: "calendar_attendees", columns: ["email"])
        }
    }

    private static func registerV14(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v14_fts_trigger_index_cleanup") { db in
            // M20: Reinstate FTS update trigger (dropped in V11).
            // Only fires when searchable content actually changes, avoiding unnecessary FTS churn.
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_fts_update
                AFTER UPDATE OF subject, snippet, body_html, body_plain ON messages
                WHEN NEW.subject IS NOT OLD.subject
                  OR NEW.snippet IS NOT OLD.snippet
                  OR NEW.body_html IS NOT OLD.body_html
                  OR NEW.body_plain IS NOT OLD.body_plain
                BEGIN
                    DELETE FROM messages_fts WHERE gmail_id = OLD.gmail_id;
                    INSERT INTO messages_fts(gmail_id, subject, body_plain, snippet, sender_name, sender_email)
                    VALUES (NEW.gmail_id, NEW.subject, NEW.body_plain, NEW.snippet, NEW.sender_name, NEW.sender_email);
                END
            """)

            // M21: Drop messages_read_state index — provides no benefit over PK.
            try db.execute(sql: "DROP INDEX IF EXISTS messages_read_state")

            // M23: Index for pruneStaleMessageContacts NOT EXISTS query.
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_contacts_source ON contacts(source, email)")
        }
    }

    // MARK: - V15

    private static func registerV15(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v15_fts_trigger_fix_sender_columns") { db in
            // Fix the FTS update trigger from V14: body_html is not an FTS column,
            // and sender_name/sender_email are FTS columns but were not watched.
            // Drop and recreate with the correct column set.
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_fts_update")
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_fts_update
                AFTER UPDATE OF subject, snippet, body_plain, sender_name, sender_email ON messages
                WHEN NEW.subject IS NOT OLD.subject
                  OR NEW.snippet IS NOT OLD.snippet
                  OR NEW.body_plain IS NOT OLD.body_plain
                  OR NEW.sender_name IS NOT OLD.sender_name
                  OR NEW.sender_email IS NOT OLD.sender_email
                BEGIN
                    DELETE FROM messages_fts WHERE gmail_id = OLD.gmail_id;
                    INSERT INTO messages_fts(gmail_id, subject, body_plain, snippet, sender_name, sender_email)
                    VALUES (NEW.gmail_id, NEW.subject, NEW.body_plain, NEW.snippet, NEW.sender_name, NEW.sender_email);
                END
            """)
        }
    }

    // MARK: - V16

    private static func registerV16(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v16_prefetch_index") { db in
            // Replace the prefetch index to include body_fetch_attempts,
            // which V12 added as a filter column in messagesNeedingBodies.
            try db.drop(index: "messages_prefetch")
            try db.create(
                index: "messages_prefetch",
                on: "messages",
                columns: ["full_body_fetched", "body_fetch_attempts", "internal_date"]
            )
        }
    }

    private static func registerV17(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17_attachment_count") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "attachment_count", .integer).notNull().defaults(to: 0)
            }
            // Backfill from attachments table for existing rows
            try db.execute(sql: """
                UPDATE messages SET attachment_count = (
                    SELECT COUNT(*) FROM attachments
                    WHERE attachments.message_id = messages.gmail_id
                ) WHERE has_attachments = 1
            """)
        }
    }
}
