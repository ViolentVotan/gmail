# Local-First GRDB Database Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace JSON file cache with GRDB SQLite database for instant email access, offline support, and snappy UI.

**Architecture:** Per-account GRDB `DatabasePool` (WAL mode) with record types mapping Gmail API models. Background sync actor writes, ViewModels read directly. SharingGRDB `@FetchAll` for reactive SwiftUI. Manual FTS5 for search.

**Tech Stack:** GRDB.swift v7.5+, SharingGRDB (Point-Free), Swift 6.2, SwiftUI, macOS 26+

**Spec:** `docs/superpowers/specs/2026-03-13-local-first-grdb-design.md`

**Rollback Strategy:**
- Phase 1 (DB alongside JSON): Rollback is trivial — stop writing to DB.
- Phase 2 (DB reads): Feature flag `UserDefaults.standard.bool(forKey: "useGRDB")` gates all DB reads. Set to `false` to revert to JSON/API reads. **Do not proceed to Phase 3 until Phase 2 is validated.**
- Phase 3 (remove old cache): Irreversible. Only execute after Phase 2 is stable.

**Critical GRDB Pattern — Column Name Mapping:**
ALL record types MUST declare snake_case column mapping since Swift properties use camelCase but database columns use snake_case:
```swift
// Add to EVERY record type:
static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
```
Without this, all database operations will crash at runtime.

**Critical GRDB Pattern — Metadata-Only Upsert:**
When syncing metadata from the API (without body content), use a custom upsert that preserves existing `body_html`/`body_plain` columns. GRDB's `upsert()` overwrites ALL columns, which would null out previously-fetched bodies. Use:
```swift
try record.upsert(db)
// Then restore body if it was a metadata-only sync:
if !record.fullBodyFetched {
    try db.execute(sql: """
        UPDATE messages SET body_html = old.body_html, body_plain = old.body_plain,
        full_body_fetched = old.full_body_fetched
        FROM (SELECT body_html, body_plain, full_body_fetched FROM messages WHERE gmail_id = ?) old
        WHERE gmail_id = ?
    """, arguments: [record.gmailId, record.gmailId])
}
```
Or better: use `INSERT ... ON CONFLICT DO UPDATE SET ... EXCLUDED` with explicit column list that omits body columns for metadata syncs.

---

## File Structure

### New Files (Phase 1)

| File | Responsibility |
|------|----------------|
| `Serif/Database/MailDatabase.swift` | DatabasePool owner, configuration, pragmas, integrity check, migrations |
| `Serif/Database/MailDatabaseMigrations.swift` | All `DatabaseMigrator` migration registrations (v1 schema) |
| `Serif/Database/Records/MessageRecord.swift` | GRDB record for `messages` table, conversion to/from `GmailMessage` and `Email` |
| `Serif/Database/Records/LabelRecord.swift` | GRDB record for `labels` table, conversion to/from `GmailLabel` |
| `Serif/Database/Records/MessageLabelRecord.swift` | GRDB record for `message_labels` join table |
| `Serif/Database/Records/ContactRecord.swift` | GRDB record for `contacts` table |
| `Serif/Database/Records/AttachmentRecord.swift` | GRDB record for `attachments` table |
| `Serif/Database/Records/EmailTagRecord.swift` | GRDB record for `email_tags` table |
| `Serif/Database/Records/FolderSyncStateRecord.swift` | GRDB record for `folder_sync_state` table |
| `Serif/Database/Records/AccountSyncStateRecord.swift` | GRDB record for `account_sync_state` table |
| `Serif/Database/MailDatabaseQueries.swift` | Centralized query methods (inbox, folder, thread, search, counts) |
| `Serif/Database/FTSManager.swift` | Centralized FTS5 maintenance (insert, update, delete, evict) |
| `Serif/Services/BackgroundSyncer.swift` | Actor for bulk API sync → DB writes |
| `SerifTests/Database/MailDatabaseTests.swift` | Tests for DB creation, migrations, integrity check |
| `SerifTests/Database/MessageRecordTests.swift` | Tests for record conversion, upsert, queries |
| `SerifTests/Database/FTSManagerTests.swift` | Tests for FTS indexing and search |
| `SerifTests/Database/BackgroundSyncerTests.swift` | Tests for sync logic |

### Modified Files (Phase 2-3)

| File | Change |
|------|--------|
| `Serif.xcodeproj/project.pbxproj` | Add GRDB + SharingGRDB SPM dependencies, new file references |
| `Serif/ViewModels/MailboxViewModel.swift` | Read from DB instead of MessageFetchService |
| `Serif/ViewModels/EmailDetailViewModel.swift` | Read thread from DB instead of API |
| `Serif/ViewModels/AppCoordinator.swift` | Own MailDatabase instances, inject DatabaseContext |
| `Serif/ContentView.swift` | Pass DatabaseContext environment |
| `Serif/Services/Gmail/GmailAPIClient.swift` | Add gzip headers, ETag support |
| `Serif/Services/MailCacheStore.swift` | Phase 3: delete entirely |
| `Serif/Services/MessageFetchService.swift` | Phase 3: delete entirely |
| `Serif/Services/ContactModels.swift` | Phase 3: remove ContactStore/ContactPhotoCache |
| `Serif/Services/AttachmentDatabase.swift` | Phase 3: delete (merged into MailDatabase) |
| `Serif/Services/AttachmentIndexer.swift` | Phase 3: use MailDatabase instead of AttachmentDatabase |

---

## Chunk 1: Foundation — Database, Schema, Records

### Task 1: Add GRDB + SharingGRDB Dependencies

**Files:**
- Modify: `Serif.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add GRDB Swift Package**

In Xcode: File → Add Package Dependencies → Enter URL:
`https://github.com/groue/GRDB.swift.git` — version 7.5.0 or later.
Add `GRDB` product to Serif target.

Cannot be done via command line — Xcode project modification required.
Use XcodeBuildMCP or manual Xcode operation.

- [ ] **Step 2: Add SharingGRDB Swift Package**

In Xcode: File → Add Package Dependencies → Enter URL:
`https://github.com/pointfreeco/sharing-grdb.git` — latest version.
Add `SharingGRDB` product to Serif target.

- [ ] **Step 3: Verify build compiles**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "deps: add GRDB.swift and SharingGRDB packages"
```

---

### Task 2: Create MailDatabase with Pragmas and Integrity Check

**Files:**
- Create: `Serif/Database/MailDatabase.swift`
- Test: `SerifTests/Database/MailDatabaseTests.swift`

- [ ] **Step 1: Write failing test for database creation**

```swift
// SerifTests/Database/MailDatabaseTests.swift
import Testing
import GRDB
@testable import Serif

@Suite("MailDatabase")
struct MailDatabaseTests {
    @Test("creates database file at expected path")
    func createsDatabaseFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try MailDatabase(accountID: "test-account", baseDirectory: tempDir)
        let dbPath = tempDir.appendingPathComponent("test-account.sqlite").path
        #expect(FileManager.default.fileExists(atPath: dbPath))
    }

    @Test("sets WAL journal mode")
    func setsWALMode() throws {
        let db = try makeTestDatabase()
        let mode = try db.dbPool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(mode == "wal")
    }

    @Test("enables foreign keys")
    func enablesForeignKeys() throws {
        let db = try makeTestDatabase()
        let fk = try db.dbPool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        #expect(fk == 1)
    }

    @Test("integrity check passes on fresh database")
    func integrityCheckPasses() throws {
        let db = try makeTestDatabase()
        #expect(try db.integrityCheck())
    }

    // Helper
    private func makeTestDatabase() throws -> MailDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Note: caller should defer cleanup in real tests
        return try MailDatabase(accountID: "test", baseDirectory: tempDir)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Serif -destination 'platform=macOS' test 2>&1 | grep -E "(Test|error|FAIL)"`
Expected: Compile error — `MailDatabase` not defined.

- [ ] **Step 3: Implement MailDatabase**

```swift
// Serif/Database/MailDatabase.swift
import Foundation
import GRDB

/// Per-account SQLite database using GRDB DatabasePool (WAL mode).
/// Each account has its own database file for isolation.
final class MailDatabase: Sendable {
    let dbPool: DatabasePool
    let accountID: String

    /// Default base directory for mail databases.
    static var defaultBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.genyus.serif.app/mail-db", isDirectory: true)
    }

    /// Creates or opens the database for the given account.
    /// - Parameters:
    ///   - accountID: The Gmail account identifier (email address).
    ///   - baseDirectory: Override for testing. Defaults to Application Support.
    init(accountID: String, baseDirectory: URL? = nil) throws {
        self.accountID = accountID
        let dir = baseDirectory ?? Self.defaultBaseDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("\(accountID).sqlite").path

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA cache_size = -64000")
        }
        #if DEBUG
        config.prepareDatabase { db in
            db.trace { print("SQL: \($0)") }
        }
        #endif

        dbPool = try DatabasePool(path: path, configuration: config)
        try MailDatabaseMigrations.migrator.migrate(dbPool)
    }

    /// Returns true if the database passes SQLite integrity check.
    func integrityCheck() throws -> Bool {
        try dbPool.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            return result == "ok"
        }
    }

    /// Deletes the database file and WAL/SHM files.
    static func deleteDatabase(accountID: String, baseDirectory: URL? = nil) {
        let dir = baseDirectory ?? defaultBaseDirectory
        let base = dir.appendingPathComponent("\(accountID).sqlite").path
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: base + suffix)
        }
    }
}
```

- [ ] **Step 4: Create stub migrations file (empty migrator)**

```swift
// Serif/Database/MailDatabaseMigrations.swift
import GRDB

enum MailDatabaseMigrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        // Migrations will be added in Task 3
        return migrator
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -scheme Serif -destination 'platform=macOS' test 2>&1 | grep -E "(Test|PASS|FAIL)"`
Expected: All 4 MailDatabase tests PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(db): add MailDatabase with GRDB DatabasePool and integrity check"
```

---

### Task 3: Schema Migrations (v1)

**Files:**
- Modify: `Serif/Database/MailDatabaseMigrations.swift`
- Test: `SerifTests/Database/MailDatabaseTests.swift` (add migration tests)

- [ ] **Step 1: Write failing tests for schema tables**

Add to `MailDatabaseTests.swift`:

```swift
@Test("v1 migration creates all tables")
func v1CreatesAllTables() throws {
    let db = try makeTestDatabase()
    let tables = try db.dbPool.read { db in
        try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            ORDER BY name
        """)
    }
    #expect(tables.contains("messages"))
    #expect(tables.contains("labels"))
    #expect(tables.contains("message_labels"))
    #expect(tables.contains("contacts"))
    #expect(tables.contains("attachments"))
    #expect(tables.contains("email_tags"))
    #expect(tables.contains("folder_sync_state"))
    #expect(tables.contains("account_sync_state"))
}

@Test("v1 migration creates FTS5 virtual table")
func v1CreatesFTS() throws {
    let db = try makeTestDatabase()
    let tables = try db.dbPool.read { db in
        try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type='table' AND name = 'messages_fts'
        """)
    }
    #expect(tables == ["messages_fts"])
}

@Test("v1 migration creates indexes")
func v1CreatesIndexes() throws {
    let db = try makeTestDatabase()
    let indexes = try db.dbPool.read { db in
        try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'messages_%'
            ORDER BY name
        """)
    }
    #expect(indexes.contains("messages_date"))
    #expect(indexes.contains("messages_thread_id"))
    #expect(indexes.contains("messages_sender"))
    #expect(indexes.contains("messages_prefetch"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — tables don't exist (empty migrator).

- [ ] **Step 3: Implement v1 migration**

Replace the migrator in `MailDatabaseMigrations.swift`:

```swift
// Serif/Database/MailDatabaseMigrations.swift
import GRDB

enum MailDatabaseMigrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        registerV1(&migrator)
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
                    .references("labels", column: "gmail_id", onDelete: .cascade)
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
                t.column("labels_etag", .text)
                t.column("last_contacts_sync", .double)
            }
            // Seed the single row
            try db.execute(sql: "INSERT INTO account_sync_state (id) VALUES (1)")

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
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: All migration tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(db): add v1 schema migration with all tables, indexes, and FTS5"
```

---

### Task 4: GmailMessage Test Fixture Helper

**Files:**
- Modify: `Serif/Services/Gmail/GmailModels.swift` (add test fixture extension)

**NOTE:** This was originally Task 9 but moved earlier because Tasks 5 and 8 depend on `GmailMessage.testFixture()`.

- [ ] **Step 1: Check if test fixture already exists**

Search for `testFixture` in GmailModels.swift and test files. If not found, create it.

- [ ] **Step 2: Add test fixture extension**

Add at bottom of `GmailModels.swift` (or in a test helper file):

```swift
#if DEBUG
extension GmailMessage {
    /// Creates a minimal test fixture for unit tests.
    static func testFixture(
        id: String = "msg-test",
        threadId: String = "thread-test",
        labelIds: [String] = ["INBOX"],
        subject: String = "Test Subject",
        from: String = "test@example.com",
        snippet: String = "Test snippet"
    ) -> GmailMessage {
        let subjectHeader = GmailHeader(name: "Subject", value: subject)
        let fromHeader = GmailHeader(name: "From", value: from)
        let payload = GmailMessagePart(
            partId: "0",
            mimeType: "text/plain",
            filename: nil,
            headers: [subjectHeader, fromHeader],
            body: GmailMessageBody(attachmentId: nil, size: 0, data: nil),
            parts: nil
        )
        return GmailMessage(
            id: id,
            threadId: threadId,
            labelIds: labelIds,
            snippet: snippet,
            internalDate: String(Int(Date().timeIntervalSince1970 * 1000)),
            payload: payload,
            sizeEstimate: 1024,
            historyId: nil,
            raw: nil
        )
    }
}
#endif
```

- [ ] **Step 3: Verify build compiles**

Run: `xcodebuild -scheme Serif -destination 'platform=macOS' test`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "test: add GmailMessage test fixture helper"
```

---

### Task 5: MessageRecord — Conversion and CRUD

**Files:**
- Create: `Serif/Database/Records/MessageRecord.swift`
- Test: `SerifTests/Database/MessageRecordTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// SerifTests/Database/MessageRecordTests.swift
import Testing
import GRDB
@testable import Serif

@Suite("MessageRecord")
struct MessageRecordTests {
    @Test("round-trips through database")
    func roundTrip() throws {
        let db = try makeTestDatabase()
        var record = MessageRecord.fixture()

        try db.dbPool.write { db in
            try record.insert(db)
        }

        let fetched = try db.dbPool.read { db in
            try MessageRecord.fetchOne(db, key: record.gmailId)
        }
        #expect(fetched?.gmailId == record.gmailId)
        #expect(fetched?.threadId == record.threadId)
        #expect(fetched?.subject == record.subject)
        #expect(fetched?.isRead == false)
        #expect(fetched?.isStarred == false)
    }

    @Test("upsert updates existing record")
    func upsertUpdates() throws {
        let db = try makeTestDatabase()
        var record = MessageRecord.fixture()

        try db.dbPool.write { db in
            try record.insert(db)
        }

        record.subject = "Updated Subject"
        record.isRead = true

        try db.dbPool.write { db in
            try record.upsert(db)
        }

        let fetched = try db.dbPool.read { db in
            try MessageRecord.fetchOne(db, key: record.gmailId)
        }
        #expect(fetched?.subject == "Updated Subject")
        #expect(fetched?.isRead == true)
    }

    @Test("converts from GmailMessage")
    func convertsFromGmailMessage() throws {
        let gmail = GmailMessage.testFixture(
            id: "msg-1",
            threadId: "thread-1",
            labelIds: ["INBOX", "UNREAD"],
            subject: "Test Subject",
            from: "sender@test.com",
            snippet: "Hello world"
        )
        let record = MessageRecord(from: gmail)
        #expect(record.gmailId == "msg-1")
        #expect(record.threadId == "thread-1")
        #expect(record.subject == "Test Subject")
        #expect(record.senderEmail == "sender@test.com")
        #expect(record.isRead == false)  // UNREAD label present
        #expect(record.isStarred == false)
    }

    @Test("queries messages by thread_id")
    func queryByThread() throws {
        let db = try makeTestDatabase()
        try db.dbPool.write { db in
            try MessageRecord.fixture(gmailId: "m1", threadId: "t1").insert(db)
            try MessageRecord.fixture(gmailId: "m2", threadId: "t1").insert(db)
            try MessageRecord.fixture(gmailId: "m3", threadId: "t2").insert(db)
        }

        let thread = try db.dbPool.read { db in
            try MessageRecord
                .filter(Column("thread_id") == "t1")
                .order(Column("internal_date").asc)
                .fetchAll(db)
        }
        #expect(thread.count == 2)
        #expect(thread.allSatisfy { $0.threadId == "t1" })
    }

    private func makeTestDatabase() throws -> MailDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try MailDatabase(accountID: "test", baseDirectory: tempDir)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: Compile error — `MessageRecord` not defined.

- [ ] **Step 3: Implement MessageRecord**

```swift
// Serif/Database/Records/MessageRecord.swift
import Foundation
import GRDB

struct MessageRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase

    // Primary key
    var gmailId: String

    // Core fields
    var threadId: String
    var historyId: String?
    var internalDate: Double
    var snippet: String?
    var sizeEstimate: Int?
    var subject: String?
    var senderEmail: String?
    var senderName: String?
    var toRecipients: String?   // JSON array
    var ccRecipients: String?   // JSON array
    var bccRecipients: String?  // JSON array
    var replyTo: String?
    var messageIdHeader: String?
    var inReplyTo: String?
    var bodyHtml: String?
    var bodyPlain: String?
    var rawHeaders: String?     // JSON array
    var hasAttachments: Bool
    var isRead: Bool
    var isStarred: Bool
    var isFromMailingList: Bool
    var unsubscribeUrl: String?
    var fullBodyFetched: Bool
    var threadMessageCount: Int
    var fetchedAt: Double?

    var id: String { gmailId }

    // MARK: - Conversion from Gmail API model

    init(from gmail: GmailMessage) {
        self.gmailId = gmail.id
        self.threadId = gmail.threadId
        self.historyId = gmail.historyId
        self.internalDate = gmail.date?.timeIntervalSince1970 ?? 0
        self.snippet = gmail.snippet
        self.sizeEstimate = gmail.sizeEstimate
        self.subject = gmail.subject
        self.senderEmail = gmail.from?.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
        self.senderName = gmail.from?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        self.toRecipients = Self.encodeRecipients(gmail.to)
        self.ccRecipients = Self.encodeRecipients(gmail.cc)
        self.bccRecipients = nil // BCC only available for sent messages via raw format
        self.replyTo = gmail.replyTo
        self.messageIdHeader = gmail.messageID
        self.inReplyTo = gmail.inReplyTo
        self.bodyHtml = gmail.htmlBody
        self.bodyPlain = gmail.plainBody
        self.rawHeaders = Self.encodeHeaders(gmail.payload?.headers)
        self.hasAttachments = gmail.attachmentParts.count > 0
        self.isRead = !(gmail.labelIds?.contains("UNREAD") ?? false)
        self.isStarred = gmail.labelIds?.contains("STARRED") ?? false
        self.isFromMailingList = gmail.isFromMailingList
        self.unsubscribeUrl = gmail.unsubscribeURL?.absoluteString
        self.fullBodyFetched = gmail.htmlBody != nil || gmail.plainBody != nil
        self.threadMessageCount = 1
        self.fetchedAt = Date().timeIntervalSince1970
    }

    // MARK: - Test fixture

    static func fixture(
        gmailId: String = "msg-\(UUID().uuidString.prefix(8))",
        threadId: String = "thread-1",
        subject: String = "Test Subject",
        senderEmail: String = "test@example.com",
        internalDate: Double = Date().timeIntervalSince1970
    ) -> MessageRecord {
        MessageRecord(
            gmailId: gmailId,
            threadId: threadId,
            historyId: nil,
            internalDate: internalDate,
            snippet: "Test snippet",
            sizeEstimate: 1024,
            subject: subject,
            senderEmail: senderEmail,
            senderName: "Test User",
            toRecipients: nil,
            ccRecipients: nil,
            bccRecipients: nil,
            replyTo: nil,
            messageIdHeader: nil,
            inReplyTo: nil,
            bodyHtml: nil,
            bodyPlain: nil,
            rawHeaders: nil,
            hasAttachments: false,
            isRead: false,
            isStarred: false,
            isFromMailingList: false,
            unsubscribeUrl: nil,
            fullBodyFetched: false,
            threadMessageCount: 1,
            fetchedAt: nil
        )
    }

    // MARK: - Private helpers

    private static func encodeRecipients(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let addresses = raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return try? String(data: JSONEncoder().encode(addresses), encoding: .utf8)
    }

    private static func encodeHeaders(_ headers: [GmailHeader]?) -> String? {
        guard let headers else { return nil }
        return try? String(data: JSONEncoder().encode(headers), encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: All MessageRecord tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(db): add MessageRecord with GmailMessage conversion and upsert"
```

---

### Task 6: Remaining Record Types

**Files:**
- Create: `Serif/Database/Records/LabelRecord.swift`
- Create: `Serif/Database/Records/MessageLabelRecord.swift`
- Create: `Serif/Database/Records/ContactRecord.swift`
- Create: `Serif/Database/Records/AttachmentRecord.swift`
- Create: `Serif/Database/Records/EmailTagRecord.swift`
- Create: `Serif/Database/Records/FolderSyncStateRecord.swift`
- Create: `Serif/Database/Records/AccountSyncStateRecord.swift`

- [ ] **Step 1: Write failing test for LabelRecord insert + association**

```swift
// Add to MessageRecordTests.swift or create new file
@Test("message-label association works")
func messageLabelAssociation() throws {
    let db = try makeTestDatabase()
    try db.dbPool.write { db in
        try LabelRecord(gmailId: "INBOX", name: "Inbox", type: "system", bgColor: nil, textColor: nil).insert(db)
        try LabelRecord(gmailId: "STARRED", name: "Starred", type: "system", bgColor: nil, textColor: nil).insert(db)
        try MessageRecord.fixture(gmailId: "m1").insert(db)
        try MessageLabelRecord(messageId: "m1", labelId: "INBOX").insert(db)
        try MessageLabelRecord(messageId: "m1", labelId: "STARRED").insert(db)
    }

    let labels = try db.dbPool.read { db in
        let msg = try MessageRecord.fetchOne(db, key: "m1")!
        return try msg.request(for: MessageRecord.labels).fetchAll(db)
    }
    #expect(labels.count == 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: Compile error — `LabelRecord`, `MessageLabelRecord` not defined.

- [ ] **Step 3: Implement all remaining records**

```swift
// Serif/Database/Records/LabelRecord.swift
import GRDB

struct LabelRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "labels"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    var gmailId: String
    var name: String
    var type: String?
    var bgColor: String?
    var textColor: String?
    var id: String { gmailId }

    init(gmailId: String, name: String, type: String?, bgColor: String?, textColor: String?) {
        self.gmailId = gmailId; self.name = name; self.type = type
        self.bgColor = bgColor; self.textColor = textColor
    }

    init(from gmail: GmailLabel) {
        self.gmailId = gmail.id
        self.name = gmail.name
        self.type = gmail.type
        self.bgColor = gmail.color?.backgroundColor
        self.textColor = gmail.color?.textColor
    }
}

// Serif/Database/Records/MessageLabelRecord.swift
import GRDB

struct MessageLabelRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "message_labels"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    var messageId: String
    var labelId: String
}

// Serif/Database/Records/ContactRecord.swift
import GRDB

struct ContactRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "contacts"
    var email: String
    var name: String?
    var photoUrl: String?
    var source: String?
    var resourceName: String?
    var updatedAt: Double?
    var id: String { email }
}

// Serif/Database/Records/AttachmentRecord.swift
import GRDB

struct AttachmentRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "attachments"
    var id: String
    var messageId: String
    var gmailAttachmentId: String
    var filename: String?
    var mimeType: String?
    var fileType: String?
    var size: Int?
    var contentId: String?
    var direction: String?
    var indexingStatus: String?
    var extractedText: String?
    var indexedAt: Double?
    var retryCount: Int?
}

// Serif/Database/Records/EmailTagRecord.swift
import GRDB

struct EmailTagRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "email_tags"
    var messageId: String
    var needsReply: Bool
    var fyiOnly: Bool
    var hasDeadline: Bool
    var financial: Bool
    var classifiedAt: Double?
    var classifierVersion: Int?
    var id: String { messageId }
}

// Serif/Database/Records/FolderSyncStateRecord.swift
import GRDB

struct FolderSyncStateRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "folder_sync_state"
    var folderKey: String
    var historyId: String?
    var nextPageToken: String?
    var lastFullSync: Double?
    var lastDeltaSync: Double?
    var id: String { folderKey }
}

// Serif/Database/Records/AccountSyncStateRecord.swift
import GRDB

struct AccountSyncStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "account_sync_state"
    var id: Int = 1
    var contactsSyncToken: String?
    var otherContactsSyncToken: String?
    var labelsEtag: String?
    var lastContactsSync: Double?
}
```

- [ ] **Step 4: Add GRDB associations to records**

Add to each record file:

```swift
// In MessageRecord.swift — add at bottom
extension MessageRecord {
    static let messageLabels = hasMany(MessageLabelRecord.self, using: ForeignKey(["message_id"]))
    static let labels = hasMany(LabelRecord.self, through: messageLabels, using: MessageLabelRecord.label)
    static let attachments = hasMany(AttachmentRecord.self, using: ForeignKey(["message_id"]))
    static let tags = hasOne(EmailTagRecord.self, using: ForeignKey(["message_id"]))
}

// In LabelRecord.swift
extension LabelRecord {
    static let messageLabels = hasMany(MessageLabelRecord.self, using: ForeignKey(["label_id"]))
    static let messages = hasMany(MessageRecord.self, through: messageLabels, using: MessageLabelRecord.message)
}

// In MessageLabelRecord.swift
extension MessageLabelRecord {
    static let message = belongsTo(MessageRecord.self, using: ForeignKey(["message_id"]))
    static let label = belongsTo(LabelRecord.self, using: ForeignKey(["label_id"]))
}
```

- [ ] **Step 5: Run all tests**

Expected: All tests PASS including association test.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(db): add all record types with associations"
```

---

### Task 7: FTSManager — Centralized Full-Text Search Maintenance

**Files:**
- Create: `Serif/Database/FTSManager.swift`
- Test: `SerifTests/Database/FTSManagerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// SerifTests/Database/FTSManagerTests.swift
import Testing
import GRDB
@testable import Serif

@Suite("FTSManager")
struct FTSManagerTests {
    @Test("indexes message and finds via search")
    func indexAndSearch() throws {
        let db = try makeTestDatabase()
        var msg = MessageRecord.fixture(gmailId: "m1", subject: "Invoice from Acme Corp")
        msg.bodyPlain = "Please find attached your invoice for March 2026."
        msg.senderName = "Billing Department"
        msg.senderEmail = "billing@acme.com"

        try db.dbPool.write { db in
            try msg.insert(db)
            try FTSManager.index(message: msg, in: db)
        }

        let results = try db.dbPool.read { db in
            try FTSManager.search(query: "invoice", in: db)
        }
        #expect(results.count == 1)
        #expect(results[0].gmailId == "m1")
    }

    @Test("update replaces old FTS content")
    func updateReplacesContent() throws {
        let db = try makeTestDatabase()
        var msg = MessageRecord.fixture(gmailId: "m1", subject: "Old Subject")
        msg.bodyPlain = "old content"

        try db.dbPool.write { db in
            try msg.insert(db)
            try FTSManager.index(message: msg, in: db)
        }

        msg.subject = "New Subject"
        msg.bodyPlain = "completely new content"

        try db.dbPool.write { db in
            try msg.upsert(db)
            try FTSManager.update(message: msg, in: db)
        }

        let oldResults = try db.dbPool.read { db in
            try FTSManager.search(query: "old", in: db)
        }
        #expect(oldResults.isEmpty)

        let newResults = try db.dbPool.read { db in
            try FTSManager.search(query: "new", in: db)
        }
        #expect(newResults.count == 1)
    }

    @Test("delete removes from FTS index")
    func deleteRemoves() throws {
        let db = try makeTestDatabase()
        var msg = MessageRecord.fixture(gmailId: "m1", subject: "Searchable")

        try db.dbPool.write { db in
            try msg.insert(db)
            try FTSManager.index(message: msg, in: db)
        }
        try db.dbPool.write { db in
            try FTSManager.delete(gmailId: "m1", in: db)
        }

        let results = try db.dbPool.read { db in
            try FTSManager.search(query: "Searchable", in: db)
        }
        #expect(results.isEmpty)
    }

    @Test("evict nulls body but keeps subject searchable")
    func evictKeepsSubject() throws {
        let db = try makeTestDatabase()
        var msg = MessageRecord.fixture(gmailId: "m1", subject: "Important Meeting")
        msg.bodyPlain = "Let's discuss the quarterly results"

        try db.dbPool.write { db in
            try msg.insert(db)
            try FTSManager.index(message: msg, in: db)
        }

        try db.dbPool.write { db in
            try FTSManager.evictBody(gmailId: "m1", subject: "Important Meeting", snippet: msg.snippet, senderName: msg.senderName, senderEmail: msg.senderEmail, in: db)
        }

        let bodyResults = try db.dbPool.read { db in
            try FTSManager.search(query: "quarterly", in: db)
        }
        #expect(bodyResults.isEmpty)

        let subjectResults = try db.dbPool.read { db in
            try FTSManager.search(query: "Meeting", in: db)
        }
        #expect(subjectResults.count == 1)
    }

    private func makeTestDatabase() throws -> MailDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try MailDatabase(accountID: "test", baseDirectory: tempDir)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: Compile error — `FTSManager` not defined.

- [ ] **Step 3: Implement FTSManager**

```swift
// Serif/Database/FTSManager.swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: All FTSManager tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(db): add FTSManager for centralized FTS5 maintenance"
```

---

### Task 8: MailDatabaseQueries — Centralized Read Queries

**Files:**
- Create: `Serif/Database/MailDatabaseQueries.swift`
- Test: `SerifTests/Database/MailDatabaseQueriesTests.swift`

- [ ] **Step 1: Write failing tests for key queries**

```swift
// SerifTests/Database/MailDatabaseQueriesTests.swift
import Testing
import GRDB
@testable import Serif

@Suite("MailDatabaseQueries")
struct MailDatabaseQueriesTests {

    @Test("inbox query returns messages with INBOX label sorted by date desc")
    func inboxQuery() throws {
        let db = try makeTestDatabase()
        try db.dbPool.write { db in
            try LabelRecord(gmailId: "INBOX", name: "Inbox", type: "system", bgColor: nil, textColor: nil).insert(db)
            try MessageRecord.fixture(gmailId: "m1", internalDate: 1000).insert(db)
            try MessageRecord.fixture(gmailId: "m2", internalDate: 2000).insert(db)
            try MessageRecord.fixture(gmailId: "m3", internalDate: 500).insert(db)
            try MessageLabelRecord(messageId: "m1", labelId: "INBOX").insert(db)
            try MessageLabelRecord(messageId: "m2", labelId: "INBOX").insert(db)
            // m3 not in INBOX
        }

        let messages = try db.dbPool.read { db in
            try MailDatabaseQueries.messagesForLabel("INBOX", limit: 50, in: db)
        }
        #expect(messages.count == 2)
        #expect(messages[0].gmailId == "m2") // newest first
        #expect(messages[1].gmailId == "m1")
    }

    @Test("thread query returns all messages in thread")
    func threadQuery() throws {
        let db = try makeTestDatabase()
        try db.dbPool.write { db in
            try MessageRecord.fixture(gmailId: "m1", threadId: "t1", internalDate: 1000).insert(db)
            try MessageRecord.fixture(gmailId: "m2", threadId: "t1", internalDate: 2000).insert(db)
            try MessageRecord.fixture(gmailId: "m3", threadId: "t2", internalDate: 3000).insert(db)
        }

        let thread = try db.dbPool.read { db in
            try MailDatabaseQueries.messagesForThread("t1", in: db)
        }
        #expect(thread.count == 2)
        #expect(thread[0].gmailId == "m1") // oldest first (ASC)
        #expect(thread[1].gmailId == "m2")
    }

    @Test("unread count for label")
    func unreadCount() throws {
        let db = try makeTestDatabase()
        try db.dbPool.write { db in
            try LabelRecord(gmailId: "INBOX", name: "Inbox", type: "system", bgColor: nil, textColor: nil).insert(db)
            var m1 = MessageRecord.fixture(gmailId: "m1"); m1.isRead = false
            var m2 = MessageRecord.fixture(gmailId: "m2"); m2.isRead = true
            var m3 = MessageRecord.fixture(gmailId: "m3"); m3.isRead = false
            try m1.insert(db); try m2.insert(db); try m3.insert(db)
            try MessageLabelRecord(messageId: "m1", labelId: "INBOX").insert(db)
            try MessageLabelRecord(messageId: "m2", labelId: "INBOX").insert(db)
            try MessageLabelRecord(messageId: "m3", labelId: "INBOX").insert(db)
        }

        let count = try db.dbPool.read { db in
            try MailDatabaseQueries.unreadCount(forLabel: "INBOX", in: db)
        }
        #expect(count == 2)
    }

    @Test("labels for message")
    func labelsForMessage() throws {
        let db = try makeTestDatabase()
        try db.dbPool.write { db in
            try LabelRecord(gmailId: "INBOX", name: "Inbox", type: "system", bgColor: nil, textColor: nil).insert(db)
            try LabelRecord(gmailId: "STARRED", name: "Starred", type: "system", bgColor: nil, textColor: nil).insert(db)
            try MessageRecord.fixture(gmailId: "m1").insert(db)
            try MessageLabelRecord(messageId: "m1", labelId: "INBOX").insert(db)
            try MessageLabelRecord(messageId: "m1", labelId: "STARRED").insert(db)
        }

        let labels = try db.dbPool.read { db in
            try MailDatabaseQueries.labels(forMessage: "m1", in: db)
        }
        #expect(labels.count == 2)
    }

    private func makeTestDatabase() throws -> MailDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try MailDatabase(accountID: "test", baseDirectory: tempDir)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement MailDatabaseQueries**

```swift
// Serif/Database/MailDatabaseQueries.swift
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
    static func missingMessageIds(from ids: [String], in db: Database) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let existing = try String.fetchAll(db, sql: """
            SELECT gmail_id FROM messages WHERE gmail_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
        """, arguments: StatementArguments(ids))
        let existingSet = Set(existing)
        return ids.filter { !existingSet.contains($0) }
    }

    /// Contact photo URL for an email address.
    static func contactPhotoUrl(forEmail email: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT photo_url FROM contacts WHERE email = ? COLLATE NOCASE
        """, arguments: [email])
    }
}
```

- [ ] **Step 4: Run all tests**

Expected: All query tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(db): add MailDatabaseQueries for inbox, thread, count, and search"
```

---

## Chunk 2: BackgroundSyncer and Integration

### Task 9: BackgroundSyncer — Folder Sync

**Files:**
- Create: `Serif/Services/BackgroundSyncer.swift`
- Test: `SerifTests/Database/BackgroundSyncerTests.swift`

- [ ] **Step 1: Write failing test for folder sync upsert**

```swift
// SerifTests/Database/BackgroundSyncerTests.swift
import Testing
import GRDB
@testable import Serif

@Suite("BackgroundSyncer")
struct BackgroundSyncerTests {

    @Test("upsertMessages inserts new messages and labels into DB")
    func upsertMessages() async throws {
        let db = try makeTestDatabase()
        let syncer = BackgroundSyncer(db: db)

        // Simulate API response
        let messages = [
            GmailMessage.testFixture(id: "m1", threadId: "t1", labelIds: ["INBOX", "UNREAD"], subject: "Hello"),
            GmailMessage.testFixture(id: "m2", threadId: "t1", labelIds: ["INBOX"], subject: "Re: Hello"),
        ]

        try await syncer.upsertMessages(messages, ensureLabels: ["INBOX", "UNREAD"])

        let count = try db.dbPool.read { db in
            try MessageRecord.fetchCount(db)
        }
        #expect(count == 2)

        let inboxCount = try db.dbPool.read { db in
            try MailDatabaseQueries.messagesForLabel("INBOX", in: db).count
        }
        #expect(inboxCount == 2)
    }

    @Test("upsertMessages updates existing message on re-sync")
    func upsertUpdatesExisting() async throws {
        let db = try makeTestDatabase()
        let syncer = BackgroundSyncer(db: db)

        let msg1 = GmailMessage.testFixture(id: "m1", threadId: "t1", labelIds: ["INBOX", "UNREAD"], subject: "Original")
        try await syncer.upsertMessages([msg1], ensureLabels: ["INBOX", "UNREAD"])

        let msg1Updated = GmailMessage.testFixture(id: "m1", threadId: "t1", labelIds: ["INBOX"], subject: "Original")
        try await syncer.upsertMessages([msg1Updated], ensureLabels: ["INBOX"])

        let fetched = try db.dbPool.read { db in
            try MessageRecord.fetchOne(db, key: "m1")
        }
        #expect(fetched?.isRead == true)  // UNREAD removed
    }

    @Test("updateThreadMessageCounts sets correct counts")
    func threadCounts() async throws {
        let db = try makeTestDatabase()
        let syncer = BackgroundSyncer(db: db)

        let messages = [
            GmailMessage.testFixture(id: "m1", threadId: "t1", labelIds: ["INBOX"], subject: "A"),
            GmailMessage.testFixture(id: "m2", threadId: "t1", labelIds: ["INBOX"], subject: "B"),
            GmailMessage.testFixture(id: "m3", threadId: "t2", labelIds: ["INBOX"], subject: "C"),
        ]
        try await syncer.upsertMessages(messages, ensureLabels: ["INBOX"])

        let m1 = try db.dbPool.read { db in try MessageRecord.fetchOne(db, key: "m1") }
        let m3 = try db.dbPool.read { db in try MessageRecord.fetchOne(db, key: "m3") }
        #expect(m1?.threadMessageCount == 2)
        #expect(m3?.threadMessageCount == 1)
    }

    private func makeTestDatabase() throws -> MailDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try MailDatabase(accountID: "test", baseDirectory: tempDir)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: Compile error — `BackgroundSyncer` not defined.

- [ ] **Step 3: Implement BackgroundSyncer core upsert**

```swift
// Serif/Services/BackgroundSyncer.swift
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
    func upsertMessages(_ gmailMessages: [GmailMessage], ensureLabels labelIds: [String]) throws {
        try db.dbPool.write { db in
            // Ensure label records exist
            for labelId in labelIds {
                let label = LabelRecord(gmailId: labelId, name: labelId, type: "system", bgColor: nil, textColor: nil)
                try label.upsert(db)
            }

            var affectedThreadIds = Set<String>()

            for gmail in gmailMessages {
                let record = MessageRecord(from: gmail)
                let existed = try MessageRecord.fetchOne(db, key: record.gmailId) != nil

                try record.upsert(db)
                affectedThreadIds.insert(record.threadId)

                // Replace message_labels for this message
                try db.execute(
                    sql: "DELETE FROM message_labels WHERE message_id = ?",
                    arguments: [record.gmailId]
                )
                for labelId in gmail.labelIds ?? [] {
                    // Ensure custom label exists
                    try LabelRecord(gmailId: labelId, name: labelId, type: nil, bgColor: nil, textColor: nil).upsert(db)
                    try MessageLabelRecord(messageId: record.gmailId, labelId: labelId).insert(db)
                }

                // FTS: index or update
                if existed {
                    try FTSManager.update(message: record, in: db)
                } else {
                    try FTSManager.index(message: record, in: db)
                }
            }

            // Update thread message counts for affected threads
            for threadId in affectedThreadIds {
                try db.execute(sql: """
                    UPDATE messages SET thread_message_count = (
                        SELECT COUNT(*) FROM messages m2 WHERE m2.thread_id = messages.thread_id
                    ) WHERE thread_id = ?
                """, arguments: [threadId])
            }
        }
    }

    // MARK: - Message Deletion

    /// Remove messages from database (e.g., from history delta).
    func deleteMessages(gmailIds: [String]) throws {
        guard !gmailIds.isEmpty else { return }
        try db.dbPool.write { db in
            for id in gmailIds {
                try FTSManager.delete(gmailId: id, in: db)
            }
            // CASCADE handles message_labels, email_tags, attachments
            try MessageRecord.deleteAll(db, keys: gmailIds)
        }
    }

    // MARK: - Body Pre-fetch Update

    /// Update message bodies after background pre-fetch.
    func updateBodies(_ updates: [(gmailId: String, html: String?, plain: String?)]) throws {
        try db.dbPool.write { db in
            for update in updates {
                try db.execute(sql: """
                    UPDATE messages
                    SET body_html = ?, body_plain = ?, full_body_fetched = 1, fetched_at = ?
                    WHERE gmail_id = ?
                """, arguments: [update.html, update.plain, Date().timeIntervalSince1970, update.gmailId])

                // Update FTS with new body content
                if let record = try MessageRecord.fetchOne(db, key: update.gmailId) {
                    var updated = record
                    updated.bodyHtml = update.html
                    updated.bodyPlain = update.plain
                    try FTSManager.update(message: updated, in: db)
                }
            }
        }
    }

    // MARK: - Label Sync

    /// Upsert labels from API.
    func upsertLabels(_ gmailLabels: [GmailLabel]) throws {
        try db.dbPool.write { db in
            for gmail in gmailLabels {
                try LabelRecord(from: gmail).upsert(db)
            }
        }
    }

    // MARK: - Contact Sync

    /// Upsert contacts from People API.
    func upsertContacts(_ contacts: [(email: String, name: String?, photoUrl: String?, source: String, resourceName: String?)]) throws {
        try db.dbPool.write { db in
            for contact in contacts {
                try ContactRecord(
                    email: contact.email.lowercased(),
                    name: contact.name,
                    photoUrl: contact.photoUrl,
                    source: contact.source,
                    resourceName: contact.resourceName,
                    updatedAt: Date().timeIntervalSince1970
                ).upsert(db)
            }
        }
    }

    // MARK: - Sync State

    /// Update folder sync state.
    func updateFolderSyncState(folderKey: String, historyId: String?, nextPageToken: String?, fullSync: Bool) throws {
        try db.dbPool.write { db in
            var state = try FolderSyncStateRecord.fetchOne(db, key: folderKey)
                ?? FolderSyncStateRecord(folderKey: folderKey)
            state.historyId = historyId ?? state.historyId
            state.nextPageToken = nextPageToken
            if fullSync {
                state.lastFullSync = Date().timeIntervalSince1970
            } else {
                state.lastDeltaSync = Date().timeIntervalSince1970
            }
            try state.upsert(db)
        }
    }

    /// Get folder sync state.
    func folderSyncState(forKey key: String) throws -> FolderSyncStateRecord? {
        try db.dbPool.read { db in
            try FolderSyncStateRecord.fetchOne(db, key: key)
        }
    }

    // MARK: - Body Eviction

    /// Evict bodies older than the given date.
    func evictBodies(olderThan date: Date) throws {
        try db.dbPool.write { db in
            let cutoff = date.timeIntervalSince1970

            // Get messages to evict
            let toEvict = try MessageRecord.fetchAll(db, sql: """
                SELECT * FROM messages
                WHERE internal_date < ? AND full_body_fetched = 1
            """, arguments: [cutoff])

            // Update FTS for each (remove body, keep subject/snippet/sender)
            for msg in toEvict {
                try FTSManager.evictBody(
                    gmailId: msg.gmailId,
                    subject: msg.subject,
                    snippet: msg.snippet,
                    senderName: msg.senderName,
                    senderEmail: msg.senderEmail,
                    in: db
                )
            }

            // Null out bodies
            try db.execute(sql: """
                UPDATE messages
                SET body_html = NULL, body_plain = NULL, full_body_fetched = 0
                WHERE internal_date < ? AND full_body_fetched = 1
            """, arguments: [cutoff])
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: All BackgroundSyncer tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(db): add BackgroundSyncer actor for bulk sync writes"
```

---

### Task 10: Shared Test Helper

**Files:**
- Create: `SerifTests/Database/TestHelpers.swift`

- [ ] **Step 1: Create shared test helper**

```swift
// SerifTests/Database/TestHelpers.swift
import Foundation
import GRDB
@testable import Serif

enum TestHelpers {
    static func makeTestDatabase() throws -> MailDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try MailDatabase(accountID: "test", baseDirectory: tempDir)
    }
}
```

Replace all `makeTestDatabase()` helpers across test files with `TestHelpers.makeTestDatabase()`.

- [ ] **Step 2: Commit**

```bash
git add -A && git commit -m "test: extract shared makeTestDatabase helper"
```

---

### Task 11: History Delta Sync in BackgroundSyncer

**Files:**
- Modify: `Serif/Services/BackgroundSyncer.swift`
- Test: `SerifTests/Database/BackgroundSyncerTests.swift`

This task wires the existing `HistorySyncService` logic into `BackgroundSyncer` to support incremental sync via Gmail History API.

- [ ] **Step 1: Write failing test for delta sync**

```swift
@Test("applyDelta inserts new messages and removes deleted ones")
func applyDelta() async throws {
    let db = try TestHelpers.makeTestDatabase()
    let syncer = BackgroundSyncer(db: db)

    // Seed existing messages
    let existing = [
        GmailMessage.testFixture(id: "m1", threadId: "t1", labelIds: ["INBOX"]),
        GmailMessage.testFixture(id: "m2", threadId: "t2", labelIds: ["INBOX"]),
    ]
    try syncer.upsertMessages(existing, ensureLabels: ["INBOX"])

    // Apply delta: m3 added, m1 deleted, m2 labels changed
    let newMessages = [GmailMessage.testFixture(id: "m3", threadId: "t3", labelIds: ["INBOX"])]
    let deletedIds = ["m1"]
    let labelUpdates: [(gmailId: String, labelIds: [String])] = [("m2", ["INBOX", "STARRED"])]

    try syncer.applyDelta(
        newMessages: newMessages,
        deletedIds: deletedIds,
        labelUpdates: labelUpdates
    )

    let count = try db.dbPool.read { db in try MessageRecord.fetchCount(db) }
    #expect(count == 2) // m2, m3 (m1 deleted)

    let m2 = try db.dbPool.read { db in try MessageRecord.fetchOne(db, key: "m2") }
    #expect(m2?.isStarred == true)
}
```

- [ ] **Step 2: Implement applyDelta**

Add to `BackgroundSyncer`:
```swift
/// Apply history delta: insert new, delete removed, update labels.
func applyDelta(
    newMessages: [GmailMessage],
    deletedIds: [String],
    labelUpdates: [(gmailId: String, labelIds: [String])]
) throws {
    try db.dbPool.write { db in
        // Delete removed messages
        for id in deletedIds {
            try FTSManager.delete(gmailId: id, in: db)
        }
        try MessageRecord.deleteAll(db, keys: deletedIds)

        // Insert new messages
        for gmail in newMessages {
            let record = MessageRecord(from: gmail)
            try record.upsert(db)
            try db.execute(sql: "DELETE FROM message_labels WHERE message_id = ?", arguments: [record.gmailId])
            for labelId in gmail.labelIds ?? [] {
                try LabelRecord(gmailId: labelId, name: labelId, type: nil, bgColor: nil, textColor: nil).upsert(db)
                try MessageLabelRecord(messageId: record.gmailId, labelId: labelId).insert(db)
            }
            try FTSManager.index(message: record, in: db)
        }

        // Update labels on existing messages
        for update in labelUpdates {
            try db.execute(sql: "DELETE FROM message_labels WHERE message_id = ?", arguments: [update.gmailId])
            for labelId in update.labelIds {
                try LabelRecord(gmailId: labelId, name: labelId, type: nil, bgColor: nil, textColor: nil).upsert(db)
                try MessageLabelRecord(messageId: update.gmailId, labelId: labelId).insert(db)
            }
            // Update denormalized columns
            let isRead = !update.labelIds.contains("UNREAD")
            let isStarred = update.labelIds.contains("STARRED")
            try db.execute(sql: """
                UPDATE messages SET is_read = ?, is_starred = ? WHERE gmail_id = ?
            """, arguments: [isRead, isStarred, update.gmailId])
        }
    }
}
```

- [ ] **Step 3: Run tests**

Expected: All BackgroundSyncer tests PASS.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(db): add history delta sync to BackgroundSyncer"
```

---

### Task 12: MessageRecord ↔ Email/GmailMessage Conversion

**Files:**
- Modify: `Serif/Database/Records/MessageRecord.swift`
- Test: `SerifTests/Database/MessageRecordTests.swift`

This is critical glue code — the conversion between database records and UI models. Without this, the ViewModel integration (Tasks 14-16) cannot work.

- [ ] **Step 1: Write failing tests for toEmail conversion**

```swift
@Test("converts MessageRecord to Email for UI display")
func toEmailConversion() throws {
    let db = try TestHelpers.makeTestDatabase()
    try db.dbPool.write { db in
        try LabelRecord(gmailId: "INBOX", name: "Inbox", type: "system", bgColor: nil, textColor: nil).insert(db)
        try LabelRecord(gmailId: "work", name: "Work", type: "user", bgColor: "#4285f4", textColor: "#ffffff").insert(db)
        var msg = MessageRecord.fixture(gmailId: "m1", subject: "Test Email")
        msg.senderEmail = "alice@example.com"
        msg.senderName = "Alice"
        msg.isRead = true
        msg.isStarred = false
        msg.hasAttachments = true
        msg.threadMessageCount = 3
        try msg.insert(db)
        try MessageLabelRecord(messageId: "m1", labelId: "INBOX").insert(db)
        try MessageLabelRecord(messageId: "m1", labelId: "work").insert(db)
    }

    let email = try db.dbPool.read { db in
        let msg = try MessageRecord.fetchOne(db, key: "m1")!
        let labels = try MailDatabaseQueries.labels(forMessage: "m1", in: db)
        return msg.toEmail(labels: labels, tags: nil)
    }

    #expect(email.subject == "Test Email")
    #expect(email.sender.email == "alice@example.com")
    #expect(email.sender.name == "Alice")
    #expect(email.isRead == true)
    #expect(email.isStarred == false)
    #expect(email.hasAttachments == true)
    #expect(email.threadMessageCount == 3)
    #expect(email.labels.count == 1) // Only user labels shown (not system)
}
```

- [ ] **Step 2: Implement toEmail()**

Add to `MessageRecord`:
```swift
/// Convert to UI Email model for display in list views.
func toEmail(labels: [LabelRecord], tags: EmailTagRecord?) -> Email {
    let sender = Contact(
        name: senderName ?? senderEmail ?? "Unknown",
        email: senderEmail ?? ""
    )
    let userLabels = labels.filter { $0.type == "user" }.map { label in
        EmailLabel(
            id: UUID(),
            name: label.name,
            color: label.bgColor ?? "#e8eaed",
            textColor: label.textColor ?? "#3c4043"
        )
    }
    // Parse recipients from JSON
    let toList = Self.decodeRecipientStrings(toRecipients)
    let ccList = Self.decodeRecipientStrings(ccRecipients)

    return Email(
        sender: sender,
        recipients: toList.map { Contact(name: $0, email: $0) },
        cc: ccList.map { Contact(name: $0, email: $0) },
        subject: subject ?? "(No Subject)",
        body: bodyHtml ?? bodyPlain ?? "",
        preview: snippet ?? "",
        date: Date(timeIntervalSince1970: internalDate),
        isRead: isRead,
        isStarred: isStarred,
        hasAttachments: hasAttachments,
        attachments: [],
        labels: userLabels,
        gmailMessageID: gmailId,
        gmailThreadID: threadId,
        threadMessageCount: threadMessageCount,
        isFromMailingList: isFromMailingList,
        unsubscribeURL: unsubscribeUrl.flatMap { URL(string: $0) }
    )
}

private static func decodeRecipientStrings(_ json: String?) -> [String] {
    guard let json, let data = json.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
}
```

**NOTE:** The exact `Email` initializer parameters must match the existing `Email.swift` model. Read `Serif/Models/Email.swift` to confirm the initializer signature and adjust accordingly.

- [ ] **Step 3: Run tests**

Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(db): add MessageRecord.toEmail() conversion for UI display"
```

---

### Task 13: API Improvements — Gzip Headers and ETag Support

**Files:**
- Modify: `Serif/Services/Gmail/GmailAPIClient.swift`

- [ ] **Step 1: Read current GmailAPIClient request method**

Read `GmailAPIClient.swift` — find where `URLRequest` headers are set. Look for existing `Accept-Encoding` and `User-Agent` headers.

- [ ] **Step 2: Add explicit gzip Accept-Encoding header**

In the `perform()` or `request()` method where URLRequest is constructed, ensure:
```swift
request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
```

Verify `User-Agent` already contains "gzip" substring (it does: `"Serif/1.0 (gzip)"`).

- [ ] **Step 3: Add ETag support for label requests**

In `GmailLabelService.listLabels()`:
- Accept optional `etag: String?` parameter
- If provided, set `If-None-Match: etag` header
- If response is 304: return nil (unchanged)
- If response is 200: extract `ETag` header from response, return labels + etag

This is a targeted change — only for labels initially. Can be extended to other endpoints later.

- [ ] **Step 4: Verify build compiles and existing tests pass**

Run: `xcodebuild -scheme Serif -destination 'platform=macOS' test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "perf: add gzip Accept-Encoding header and ETag support for labels"
```

---

## Chunk 3: ViewModel Integration (Phase 2)

### Task 14: AppCoordinator — Own MailDatabase Instances

**Files:**
- Modify: `Serif/ViewModels/AppCoordinator.swift`

- [ ] **Step 1: Read current AppCoordinator**

Read `AppCoordinator.swift` to understand account lifecycle, how `accountID` is managed, and where to inject `MailDatabase`.

- [ ] **Step 2: Add MailDatabase management**

Add to AppCoordinator:
```swift
// Property
private(set) var mailDatabase: MailDatabase?

// In account switch or setup method:
func setupDatabase(for accountID: String) {
    do {
        let db = try MailDatabase(accountID: accountID)
        if !(try db.integrityCheck()) {
            // Corrupt — delete and recreate
            MailDatabase.deleteDatabase(accountID: accountID)
            self.mailDatabase = try MailDatabase(accountID: accountID)
        } else {
            self.mailDatabase = db
        }
    } catch {
        print("Failed to create database: \(error)")
        self.mailDatabase = nil
    }
}
```

Call `setupDatabase()` wherever the current code sets `accountID` (in `switchAccount`, `handleAppear`, etc.).

- [ ] **Step 3: Verify build compiles**

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: integrate MailDatabase lifecycle into AppCoordinator"
```

---

### Task 15: MailboxViewModel — Read from Database

**Files:**
- Modify: `Serif/ViewModels/MailboxViewModel.swift`

- [ ] **Step 1: Read current MailboxViewModel**

Read `MailboxViewModel.swift` to understand `loadFolder()`, `performFetch()`, `refreshCurrentFolder()`, and how `messages`/`emails` are populated.

- [ ] **Step 2: Add database-backed message loading**

This is the largest single change. The strategy:

1. Add a `mailDatabase: MailDatabase?` property (injected from AppCoordinator)
2. Add a `ValueObservation` that watches the inbox query and pushes results to `messages`
3. In `loadFolder()`: if `mailDatabase` is available, query DB first (instant), then trigger background sync
4. Keep the existing API-based path as fallback (if DB is nil or empty)

Key change in `performFetch()`:
```swift
// NEW: Try database first
if let db = mailDatabase {
    let dbMessages = try await db.dbPool.read { db in
        try MailDatabaseQueries.messagesForLabel(labelId, limit: pageSize, in: db)
    }
    if !dbMessages.isEmpty {
        // Serve from DB instantly
        self.messages = dbMessages.map { ... } // Convert MessageRecord → GmailMessage
        self.recomputeEmails()
        // Then sync in background
        Task { try await backgroundSyncer?.syncFolder(...) }
        return
    }
}
// EXISTING: Fall through to API fetch
```

- [ ] **Step 3: Add ValueObservation for live updates**

```swift
private var messageObservation: DatabaseCancellable?

func startObservingInbox(labelId: String) {
    guard let db = mailDatabase else { return }
    let observation = ValueObservation.tracking { db in
        try MailDatabaseQueries.messagesForLabel(labelId, limit: 200, in: db)
    }
    messageObservation = observation.start(
        in: db.dbPool,
        onError: { error in print("Observation error: \(error)") },
        onChange: { [weak self] records in
            Task { @MainActor in
                self?.handleDatabaseUpdate(records)
            }
        }
    )
}
```

- [ ] **Step 4: Verify build compiles and existing tests pass**

Expected: BUILD SUCCEEDED, existing tests PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: read inbox from GRDB database with ValueObservation"
```

---

### Task 16: EmailDetailViewModel — Read Thread from Database

**Files:**
- Modify: `Serif/ViewModels/EmailDetailViewModel.swift`

- [ ] **Step 1: Read current EmailDetailViewModel.loadThread()**

Understand the current flow: disk cache → API fetch → render.

- [ ] **Step 2: Add database-backed thread loading**

In `loadThread(id:)`:
```swift
// NEW: Try database first (instant)
if let db = mailDatabase {
    let threadMessages = try await db.dbPool.read { db in
        try MailDatabaseQueries.messagesForThread(threadId, in: db)
    }
    if !threadMessages.isEmpty {
        let allHaveBodies = threadMessages.allSatisfy { $0.fullBodyFetched }
        // Convert to GmailThread and render
        self.thread = GmailThread(from: threadMessages)
        if allHaveBodies {
            self.isLoading = false
            // Background: check for newer messages
        } else {
            // Show what we have, fetch missing bodies in background
        }
        return
    }
}
// EXISTING: Fall through to API fetch
```

- [ ] **Step 3: Verify build compiles**

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: load thread detail from GRDB database"
```

---

### Task 17: Label Counts from Database

**Files:**
- Modify: `Serif/ViewModels/MailboxViewModel.swift` (or `LabelSyncService.swift`)

- [ ] **Step 1: Read current loadCategoryUnreadCounts()**

Understand how category counts are currently fetched (API per label).

- [ ] **Step 2: Replace with database queries**

```swift
func loadCategoryUnreadCounts() async {
    guard let db = mailDatabase else {
        // Fall back to existing API-based counts
        await loadCategoryUnreadCountsFromAPI()
        return
    }
    do {
        let counts = try db.dbPool.read { db in
            var result: [String: Int] = [:]
            for category in InboxCategory.allCases {
                for labelId in category.gmailLabelIDs {
                    result[labelId] = try MailDatabaseQueries.unreadCount(forLabel: labelId, in: db)
                }
            }
            return result
        }
        // Update UI with counts
        self.categoryUnreadCounts = counts
    } catch {
        await loadCategoryUnreadCountsFromAPI()
    }
}
```

- [ ] **Step 3: Verify build compiles**

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "perf: compute label unread counts from local database"
```

---

### Task 18: Background Body Pre-fetcher

**Files:**
- Modify: `Serif/Services/BackgroundSyncer.swift`
- Modify: `Serif/ViewModels/AppCoordinator.swift`

- [ ] **Step 1: Add preFetchBodies to BackgroundSyncer**

```swift
/// Pre-fetch full message bodies for messages that only have metadata.
/// Fetches newest first. Runs continuously until all visible messages have bodies.
func preFetchBodies(messageService: GmailMessageService, accountID: String) async throws {
    let toFetch = try db.dbPool.read { db in
        try MailDatabaseQueries.messagesNeedingBodies(limit: 50, in: db)
    }
    guard !toFetch.isEmpty else { return }

    let ids = toFetch.map(\.gmailId)
    let fullMessages = try await messageService.getMessages(ids: ids, accountID: accountID, format: .full)

    let updates: [(gmailId: String, html: String?, plain: String?)] = fullMessages.map { msg in
        (gmailId: msg.id, html: msg.htmlBody, plain: msg.plainBody)
    }
    try updateBodies(updates)
}
```

- [ ] **Step 2: Schedule pre-fetch after sync in AppCoordinator**

In the existing refresh flow (after `syncFolder` or `applyHistoryDelta`):
```swift
// After sync completes:
Task.detached(priority: .utility) { [syncer, messageService, accountID] in
    try? await syncer?.preFetchBodies(messageService: messageService, accountID: accountID)
}
```

- [ ] **Step 3: Verify build compiles**

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: background pre-fetch message bodies after sync"
```

---

### Task 19: DatabaseContext for SharingGRDB

**Files:**
- Modify: `Serif/ContentView.swift`
- Modify: `Serif/ViewModels/AppCoordinator.swift`

- [ ] **Step 1: Read current ContentView and environment setup**

Understand how the root view is structured and where environment modifiers are applied.

- [ ] **Step 2: Inject DatabaseContext**

In ContentView (or SerifApp.swift, wherever the root view is):
```swift
import SharingGRDB

// When the active database changes:
.databaseContext(.readOnly { coordinator.mailDatabase?.dbPool ?? DatabaseQueue() })
```

This needs to update when `coordinator.mailDatabase` changes (on account switch).

- [ ] **Step 3: Verify build compiles**

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: inject SharingGRDB DatabaseContext into SwiftUI environment"
```

---

## Chunk 4: Cleanup (Phase 3)

### Task 20: Search Integration via FTS5

**Files:**
- Modify: `Serif/ViewModels/MailboxViewModel.swift` (or relevant search ViewModel)

- [ ] **Step 1: Read current search implementation**

Find where the search query is constructed and sent to the API (`q=` parameter). Understand how results are displayed.

- [ ] **Step 2: Add FTS5 local search path**

When `mailDatabase` is available, search locally first:
```swift
func search(query: String) async {
    guard let db = mailDatabase else {
        await searchViaAPI(query: query)
        return
    }
    do {
        let results = try db.dbPool.read { db in
            try FTSManager.search(query: query, in: db)
        }
        let labels = try db.dbPool.read { db in
            // Fetch labels for each result
            var allLabels: [String: [LabelRecord]] = [:]
            for msg in results {
                allLabels[msg.gmailId] = try MailDatabaseQueries.labels(forMessage: msg.gmailId, in: db)
            }
            return allLabels
        }
        self.messages = results.map { msg in
            // Convert to display model using toEmail()
        }
        // If few local results, also search API for messages not yet in DB
        if results.count < 10 {
            await searchViaAPI(query: query) // supplements local results
        }
    } catch {
        await searchViaAPI(query: query)
    }
}
```

- [ ] **Step 3: Verify build compiles**

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: add local FTS5 search with API fallback"
```

---

### Task 21: Migrate Existing JSON Cache to Database (one-time)

**Files:**
- Create: `Serif/Database/CacheMigration.swift`

- [ ] **Step 1: Implement one-time migration**

```swift
// Serif/Database/CacheMigration.swift
import Foundation
import GRDB

/// One-time migration from JSON file cache to GRDB database.
/// Runs on first launch after database is introduced.
enum CacheMigration {
    private static let migrationKey = "com.serif.dbMigrationCompleted"

    static var needsMigration: Bool {
        !UserDefaults.standard.bool(forKey: migrationKey)
    }

    /// Migrate existing JSON cache data into the database.
    static func migrateIfNeeded(db: MailDatabase, accountID: String) async throws {
        guard needsMigration else { return }

        let cacheStore = MailCacheStore.shared
        let syncer = BackgroundSyncer(db: db)

        // Migrate labels
        let labels = cacheStore.loadLabels(accountID: accountID)
        if !labels.isEmpty {
            try syncer.upsertLabels(labels)
        }

        // Migrate messages from all folder caches
        let cacheDir = MailCacheStore.shared.baseDir
            .appendingPathComponent(accountID, isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) {
            for file in contents where file.hasSuffix(".json") && !file.hasPrefix("_") && file != "snoozed.json" && file != "scheduled.json" {
                let folderKey = String(file.dropLast(5)) // remove .json
                if let cache = cacheStore.loadFolderCache(accountID: accountID, folderKey: folderKey) {
                    try syncer.upsertMessages(cache.messages, ensureLabels: [])
                }
            }
        }

        // Migrate threads
        let threadsDir = cacheDir.appendingPathComponent("threads", isDirectory: true)
        if let threadFiles = try? FileManager.default.contentsOfDirectory(atPath: threadsDir.path) {
            for file in threadFiles where file.hasSuffix(".json") {
                let threadId = String(file.dropLast(5))
                if let thread = cacheStore.loadThread(accountID: accountID, threadID: threadId) {
                    if let messages = thread.messages {
                        try syncer.upsertMessages(messages, ensureLabels: [])
                    }
                }
            }
        }

        // Migrate email tags
        cacheStore.loadTagsFromDisk(accountID: accountID)
        // Tags are loaded into cacheStore.tagStore — iterate and insert into DB
        // (Implementation depends on exposing tagStore or adding a method to MailCacheStore)

        UserDefaults.standard.set(true, forKey: "\(migrationKey).\(accountID)")
    }
}
```

- [ ] **Step 2: Call migration from AppCoordinator**

In `setupDatabase()` or `switchAccount()`:
```swift
if CacheMigration.needsMigration {
    Task {
        try? await CacheMigration.migrateIfNeeded(db: mailDatabase!, accountID: accountID)
    }
}
```

- [ ] **Step 3: Verify build compiles**

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: one-time JSON cache to GRDB database migration"
```

---

### Task 22: Remove Old Cache Code (Phase 3)

**This task should only be done after Phase 2 is verified working.**

**Files:**
- Delete: `Serif/Services/MailCacheStore.swift`
- Delete: `Serif/Services/MessageFetchService.swift`
- Modify: `Serif/Services/ContactModels.swift` (remove ContactStore, ContactPhotoCache)
- Delete: `Serif/Services/AttachmentDatabase.swift` (after merging into MailDatabase)
- Modify: `Serif/Services/Protocols/CacheStoring.swift` (remove or update protocol)
- Modify: `Serif/Services/AttachmentIndexer.swift` (use MailDatabase)
- Clean up JSON cache files from disk

- [ ] **Step 1: Verify all reads go through database**

Audit all callsites of:
- `MailCacheStore.loadFolderCache` → should be `MailDatabaseQueries.messagesForLabel`
- `MailCacheStore.loadThread` → should be `MailDatabaseQueries.messagesForThread`
- `MailCacheStore.loadLabels` → should be `MailDatabaseQueries.allLabels`
- `MessageFetchService.messageCache` → should be gone
- `ContactPhotoCache.get()` → should be `MailDatabaseQueries.contactPhotoUrl`

- [ ] **Step 2: Delete MailCacheStore.swift**

Remove file, fix all compile errors by replacing with database calls.

- [ ] **Step 3: Delete MessageFetchService.swift**

Remove file, fix all compile errors. The `MessageFetching` protocol may need updating or removal.

- [ ] **Step 4: Simplify ContactModels.swift**

Remove `ContactStore` class and `ContactPhotoCache` singleton. Keep model structs (`StoredContact`, `PersonResource`, etc.) as they're used for People API deserialization.

- [ ] **Step 5: Update AttachmentIndexer to use MailDatabase**

Replace `AttachmentDatabase` calls with `MailDatabase` calls. The `attachments` table is now in the mail database.

- [ ] **Step 6: Delete AttachmentDatabase.swift**

Remove file after AttachmentIndexer is updated.

- [ ] **Step 7: Add cleanup of old JSON cache files on launch**

```swift
// In AppCoordinator or MailDatabase init:
let oldCacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("com.genyus.serif.app/mail-cache")
try? FileManager.default.removeItem(at: oldCacheDir)

let oldAttachmentDb = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("com.genyus.serif.app/attachment-index.sqlite")
for suffix in ["", "-wal", "-shm"] {
    try? FileManager.default.removeItem(atPath: oldAttachmentDb.path + suffix)
}
```

- [ ] **Step 8: Run all tests**

Expected: All tests PASS. Some old tests may need updating if they relied on MailCacheStore/MessageFetchService.

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "refactor: remove JSON cache, MessageFetchService, and standalone AttachmentDatabase"
```

---

### Task 23: Final Verification

- [ ] **Step 1: Build release configuration**

Run: `xcodebuild -scheme Serif -configuration Release build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Run full test suite**

Run: `xcodebuild -scheme Serif -destination 'platform=macOS' test`
Expected: All tests PASS

- [ ] **Step 3: Manual smoke test**

Launch app, verify:
1. Inbox loads instantly from DB on second launch
2. Clicking an email opens thread instantly (after bodies pre-fetched)
3. Folder switch is instant
4. Star/read/archive reflect immediately
5. Search works via FTS5
6. New emails appear within 120s (delta sync)
7. Multi-account switching works
8. App works offline (cached content available)

- [ ] **Step 4: Commit and tag**

```bash
git add -A && git commit -m "feat: complete local-first GRDB migration"
```
