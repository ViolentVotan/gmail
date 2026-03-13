# Local-First Email Database with GRDB

**Date:** 2026-03-13
**Status:** Draft
**Goal:** Replace JSON file cache with a GRDB-backed SQLite database so all emails are stored locally, thread opens are instant, and the app works offline.

---

## Problem

1. **Slow thread opens** — clicking an email triggers a full-format API call (500-1500ms) unless the thread was previously viewed and cached.
2. **No pre-fetching** — threads are only cached after first open. There is no background download of message bodies.
3. **Fragile JSON cache** — per-folder JSON files with no indexing, no relational queries, no FTS, unbounded growth.
4. **Re-fetching on folder switch** — switching folders re-reads JSON from disk + hits the API. No in-memory cross-folder cache.
5. **Contact photo URLs lost on restart** — `ContactPhotoCache` is in-memory only.
6. **No HTTP conditional requests** — every API call re-downloads full responses even if unchanged (no ETag / If-None-Match).
7. **Label counts always fetched from API** — sidebar unread badges require API calls, not local queries.

## Solution

Replace the JSON file cache (`MailCacheStore`, `MessageFetchService` in-memory cache) with a per-account GRDB `DatabasePool` backed by SQLite. All messages, labels, contacts, and tags are stored in the database. Reads are instant (local SQLite queries). Writes happen in the background after API sync. SwiftUI views observe database changes via SharingGRDB's `@FetchAll` / `@FetchOne` property wrappers or GRDB's `ValueObservation`.

## Technology

| Dependency | Purpose |
|---|---|
| **GRDB.swift** (v7.5+) | SQLite toolkit — DatabasePool, migrations, FTS5, associations, ValueObservation |
| **SharingGRDB** (Point-Free) | SwiftUI property wrappers (`@FetchAll`, `@FetchOne`) for reactive database queries |

**Why not SwiftData:** No FTS5, no batch insert API, no raw SQL escape hatch, no WAL tuning, poor performance at 100K+ records.

**SharingGRDB integration:** Requires a `DatabaseContext` in the SwiftUI environment. For multi-account support, the `DatabaseContext` must be swapped when the active account changes. This is done by updating the `.databaseContext()` environment modifier on the root view when `AppCoordinator.activeAccountID` changes. Each `MailDatabase` instance provides its own `DatabaseContext`.

---

## Database Schema

One SQLite database per account at:
`~/Library/Application Support/com.genyus.serif.app/mail-db/{accountID}.sqlite`

Pragmas set via `Configuration.prepareDatabase` (per-connection, not in migrations):
```swift
var config = Configuration()
config.prepareDatabase { db in
    try db.execute(sql: "PRAGMA journal_mode = WAL")
    try db.execute(sql: "PRAGMA synchronous = NORMAL")
    try db.execute(sql: "PRAGMA foreign_keys = ON")
    try db.execute(sql: "PRAGMA cache_size = -64000")  // 64MB
}
```

**Why `prepareDatabase` instead of migrations:** Pragmas like `foreign_keys` and `journal_mode` are connection-level settings that reset on each connection open. GRDB runs migrations inside transactions, where `PRAGMA journal_mode` silently fails. `prepareDatabase` runs on every connection, ensuring consistent behavior.

### Tables

Since each account has its own database file, `account_id` columns are omitted from all tables — account scoping is achieved by the database file itself.

#### `messages`
Primary store for all email message content and metadata.

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `gmail_id` | TEXT | PRIMARY KEY | Gmail message ID |
| `thread_id` | TEXT | NOT NULL, INDEXED | Links messages within a thread |
| `history_id` | TEXT | | For staleness detection |
| `internal_date` | REAL | NOT NULL, INDEXED | Unix timestamp (ms), for sorting |
| `snippet` | TEXT | | Truncated preview |
| `size_estimate` | INTEGER | | Bytes |
| `subject` | TEXT | | Extracted from headers |
| `sender_email` | TEXT | INDEXED | From header, for search/filter |
| `sender_name` | TEXT | | Display name |
| `to_recipients` | TEXT | | JSON array of {name, email} |
| `cc_recipients` | TEXT | | JSON array of {name, email} |
| `bcc_recipients` | TEXT | | JSON array of {name, email} (for sent messages) |
| `reply_to` | TEXT | | Reply-To header value |
| `message_id_header` | TEXT | | Message-ID header (RFC 2822) |
| `in_reply_to` | TEXT | | In-Reply-To header |
| `body_html` | TEXT | | Full HTML body (nullable until fetched) |
| `body_plain` | TEXT | | Plain text body |
| `raw_headers` | TEXT | | JSON array of all headers (for security info, List-Unsubscribe, etc.) |
| `has_attachments` | INTEGER | NOT NULL DEFAULT 0 | Boolean flag |
| `is_read` | INTEGER | NOT NULL DEFAULT 0 | Denormalized from labels (avoids join for list display) |
| `is_starred` | INTEGER | NOT NULL DEFAULT 0 | Denormalized from labels (avoids join for list display) |
| `is_from_mailing_list` | INTEGER | NOT NULL DEFAULT 0 | Boolean flag |
| `unsubscribe_url` | TEXT | | Parsed from List-Unsubscribe |
| `full_body_fetched` | INTEGER | NOT NULL DEFAULT 0 | 0 = metadata only, 1 = full content available |
| `thread_message_count` | INTEGER | NOT NULL DEFAULT 1 | Denormalized count, updated during sync |
| `fetched_at` | REAL | | When this row was last synced from API |

**Denormalized columns:** `is_read`, `is_starred`, and `thread_message_count` are denormalized for list display performance. They are updated atomically when labels change or threads are synced. The authoritative source remains `message_labels`, but the list query avoids joins by reading these columns directly.

**`thread_message_count` maintenance:** Updated via explicit SQL after any insert or delete that affects a thread:
```sql
UPDATE messages SET thread_message_count = (
    SELECT COUNT(*) FROM messages m2 WHERE m2.thread_id = messages.thread_id
) WHERE thread_id = ?
```
This runs inside the same write transaction as the insert/delete. Not a trigger — kept explicit in `BackgroundSyncer` to avoid hidden performance costs on bulk inserts. During bulk sync, the count update is batched: run once per affected `thread_id` after all inserts complete, not per-row.

**Indexes:**
- `messages_thread_id` on `(thread_id)`
- `messages_date` on `(internal_date DESC)` — primary list query
- `messages_sender` on `(sender_email)`
- `messages_prefetch` on `(full_body_fetched, internal_date DESC)` — for background pre-fetch queue

#### `labels`
Gmail labels (system + custom).

| Column | Type | Constraints |
|---|---|---|
| `gmail_id` | TEXT | PRIMARY KEY |
| `name` | TEXT | NOT NULL |
| `type` | TEXT | | system, user |
| `bg_color` | TEXT | | Hex color |
| `text_color` | TEXT | | Hex color |

#### `message_labels`
Many-to-many join between messages and labels.

| Column | Type | Constraints |
|---|---|---|
| `message_id` | TEXT | NOT NULL, FK → messages(gmail_id) ON DELETE CASCADE |
| `label_id` | TEXT | NOT NULL, FK → labels(gmail_id) ON DELETE CASCADE |

**Primary key:** `(message_id, label_id)`
**Indexes:**
- `message_labels_label` on `(label_id)` — for "all messages with label X" queries
- `message_labels_message` on `(message_id)` — for "all labels on message X" queries

#### `contacts`
Merged contacts from People API (My Contacts + Other Contacts).

| Column | Type | Constraints |
|---|---|---|
| `email` | TEXT | PRIMARY KEY, COLLATE NOCASE | Case-insensitive email matching |
| `name` | TEXT | |
| `photo_url` | TEXT | | Persisted (currently lost on restart) |
| `source` | TEXT | | "contacts" or "other_contacts" |
| `resource_name` | TEXT | | People API resource name |
| `updated_at` | REAL | | Last sync timestamp |

**COLLATE NOCASE** on `email` ensures `User@example.com` and `user@example.com` resolve to the same row, matching the existing `ContactPhotoCache` behavior which lowercases keys.

#### `attachments`
Replaces current `AttachmentDatabase`. Unified with mail database.

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | TEXT | PRIMARY KEY | `{messageId}_{attachmentId}` |
| `message_id` | TEXT | NOT NULL, FK → messages(gmail_id) ON DELETE CASCADE | |
| `gmail_attachment_id` | TEXT | NOT NULL | |
| `filename` | TEXT | | |
| `mime_type` | TEXT | | |
| `file_type` | TEXT | | doc, pdf, image, etc. |
| `size` | INTEGER | | |
| `content_id` | TEXT | | For inline images (CID references). New column — not in old AttachmentDatabase. Populated from MIME part Content-ID header during sync. |
| `direction` | TEXT | | "sent" or "received" |
| `indexing_status` | TEXT | DEFAULT 'pending' | pending, indexed, failed, unsupported |
| `extracted_text` | TEXT | | OCR/PDF text extraction |
| `indexed_at` | REAL | | |
| `retry_count` | INTEGER | DEFAULT 0 | |

**Column mapping from current AttachmentDatabase:** The current standalone `attachment-index.sqlite` has additional denormalized columns (`senderEmail`, `senderName`, `emailSubject`, `emailBody`, `emailDate`) that were needed because the old system had no join capability. In the unified database, these are accessed via the `message_id` foreign key join to `messages`. The following columns are intentionally dropped (with replacement):

| Dropped column | Replacement |
|---|---|
| `senderEmail` | `JOIN messages ON gmail_id = message_id` → `sender_email` |
| `senderName` | `JOIN messages` → `sender_name` |
| `emailSubject` | `JOIN messages` → `subject` |
| `emailBody` | `JOIN messages` → `body_plain` |
| `emailDate` | `JOIN messages` → `internal_date` |
| `embedding` | Dropped — unused placeholder, never populated |

**Indexes:**
- `attachments_message` on `(message_id)`
- `attachments_status` on `(indexing_status)` — for background processing queue

**Old AttachmentDatabase auxiliary tables:** The current standalone `attachment-index.sqlite` has two additional tables: `scanned_messages` (tracks which messages have been scanned for attachments) and `scan_state` (tracks pagination progress per account). These are replaced by:
- `scanned_messages` → replaced by the `attachments` table itself. If a message has rows in `attachments`, it has been scanned. For messages with no attachments, the `messages.has_attachments = 0` flag is authoritative.
- `scan_state` → absorbed into `folder_sync_state`. The attachment scanner's `pageToken` and `isComplete` state can be stored as additional columns on the folder sync row, or as a dedicated `attachment_scan_state` row in `folder_sync_state`.

#### `email_tags`
AI classification results (replaces `_tags.json`).

| Column | Type | Constraints |
|---|---|---|
| `message_id` | TEXT | PRIMARY KEY, FK → messages(gmail_id) ON DELETE CASCADE |
| `needs_reply` | INTEGER | NOT NULL DEFAULT 0 |
| `fyi_only` | INTEGER | NOT NULL DEFAULT 0 |
| `has_deadline` | INTEGER | NOT NULL DEFAULT 0 |
| `financial` | INTEGER | NOT NULL DEFAULT 0 |
| `classified_at` | REAL | | Timestamp of classification |
| `classifier_version` | INTEGER | | For re-classification on app update |

#### `folder_sync_state`
Tracks sync progress per folder.

| Column | Type | Constraints |
|---|---|---|
| `folder_key` | TEXT | PRIMARY KEY |
| `history_id` | TEXT | | For Gmail History API delta sync |
| `next_page_token` | TEXT | | For resuming API pagination |
| `last_full_sync` | REAL | | Timestamp of last complete sync |
| `last_delta_sync` | REAL | | Timestamp of last incremental sync |

#### `account_sync_state`
Account-wide sync metadata. Single row per database.

| Column | Type | Constraints |
|---|---|---|
| `id` | INTEGER | PRIMARY KEY DEFAULT 1, CHECK(id = 1) | Single-row table |
| `contacts_sync_token` | TEXT | | People API sync token |
| `other_contacts_sync_token` | TEXT | | Other Contacts sync token |
| `labels_etag` | TEXT | | For conditional label refresh |
| `last_contacts_sync` | REAL | | Timestamp |

### Virtual Tables (FTS5)

```sql
CREATE VIRTUAL TABLE messages_fts USING fts5(
    gmail_id UNINDEXED,
    subject,
    body_plain,
    snippet,
    sender_name,
    sender_email,
    tokenize='porter unicode61'
);
```

**Manual FTS5 table** (not content-sync). The `messages` table uses a TEXT primary key (`gmail_id`), which makes `content_rowid` problematic. Instead, the FTS table is maintained explicitly during write transactions.

**FTS5 does not support `INSERT OR REPLACE`.** All upserts must use DELETE-then-INSERT:

- **On message insert with body:**
  ```sql
  INSERT INTO messages_fts(gmail_id, subject, body_plain, snippet, sender_name, sender_email)
  VALUES (?, ?, ?, ?, ?, ?)
  ```
- **On message update (body pre-fetch, label change, etc.):**
  ```sql
  DELETE FROM messages_fts WHERE gmail_id = ?;
  INSERT INTO messages_fts(gmail_id, subject, body_plain, snippet, sender_name, sender_email)
  VALUES (?, ?, ?, ?, ?, ?);
  ```
- **On message delete:** `DELETE FROM messages_fts WHERE gmail_id = ?`
- **On body eviction:** Same DELETE-then-INSERT pattern, with `body_plain` set to NULL (subject/snippet/sender remain searchable)

**All FTS maintenance MUST be centralized** in a single method on `MailDatabase` (e.g., `updateFTSIndex(for:in:)`) to prevent callers from forgetting a write path. Every code path that modifies `subject`, `body_plain`, `snippet`, `sender_name`, or `sender_email` on `messages` must call through this method.

The `gmail_id` column is `UNINDEXED` (not searchable) but stored for joining back to `messages`. Search queries use a subquery to avoid scanning the unindexed `gmail_id` column on large result sets:
```sql
SELECT m.* FROM messages m
WHERE m.gmail_id IN (
    SELECT gmail_id FROM messages_fts WHERE messages_fts MATCH ?
)
ORDER BY m.internal_date DESC
```

### Associations (GRDB)

Foreign keys must be specified explicitly because column names don't follow GRDB's naming conventions:

```swift
// Message associations
extension MessageRecord: TableRecord {
    static let messageLabels = hasMany(MessageLabelRecord.self, using: ForeignKey(["message_id"]))
    static let labels = hasMany(LabelRecord.self, through: messageLabels, using: MessageLabelRecord.label)
    static let attachments = hasMany(AttachmentRecord.self, using: ForeignKey(["message_id"]))
    static let tags = hasOne(EmailTagRecord.self, using: ForeignKey(["message_id"]))
}

// Label associations
extension LabelRecord: TableRecord {
    static let messageLabels = hasMany(MessageLabelRecord.self, using: ForeignKey(["label_id"]))
    static let messages = hasMany(MessageRecord.self, through: messageLabels, using: MessageLabelRecord.message)
}

// Join table
extension MessageLabelRecord: TableRecord {
    static let message = belongsTo(MessageRecord.self, using: ForeignKey(["message_id"]))
    static let label = belongsTo(LabelRecord.self, using: ForeignKey(["label_id"]))
}
```

---

## Architecture

### Layer Diagram

```
┌────────────────────────────────────────────────┐
│  SwiftUI Views                                 │
│  @FetchAll / @FetchOne (SharingGRDB)           │
│  or ValueObservation in ViewModels             │
└──────────────────┬─────────────────────────────┘
                   │ reads (DatabasePool.read / concurrentRead)
                   ▼
┌────────────────────────────────────────────────┐
│  MailDatabase (per account)                    │
│  - DatabasePool (WAL, concurrent readers)      │
│  - DatabaseMigrator (versioned schema)         │
│  - Record types (FetchableRecord + Persistable)│
└──────────┬────────────────────┬────────────────┘
           │ bulk writes        │ lightweight writes
           ▼                    ▼
┌──────────────────┐  ┌─────────────────────────┐
│  BackgroundSyncer│  │  Direct dbPool.write {}  │
│  (Swift actor)   │  │  (optimistic UI updates) │
│                  │  │  - mark read/unread       │
│  - Bulk upserts  │  │  - star/unstar            │
│  - History delta │  │  - archive/trash          │
│  - Contact sync  │  └─────────────────────────┘
│  - FTS maintain  │
│  - Body pre-fetch│            ▲ observes
└────────┬─────────┘  ┌─────────────────────────┐
         │             │  ValueObservation /      │
         │             │  @FetchAll auto-refresh  │
         │             └─────────────────────────┘
         │ fetches raw data
         ▼
┌────────────────────────────────────────────────┐
│  Gmail API Services (unchanged)                │
│  GmailAPIClient, GmailMessageService, etc.     │
└────────────────────────────────────────────────┘
```

### Write Path Design

**Two write paths** to avoid bottlenecks:

1. **BackgroundSyncer (actor)** — bulk operations: sync, pre-fetch, batch upsert, contact sync. These are long-running and should not block user actions.

2. **Direct `dbPool.write {}`** — lightweight single-row writes for optimistic UI: mark read, star, archive, label changes. Called from `@MainActor` ViewModels. GRDB's `DatabasePool` with WAL safely serializes writes at the SQLite level — no actor needed for correctness.

This means user actions (star, read, archive) write to DB instantly (<1ms) without waiting for a sync cycle.

### Key Components

#### `MailDatabase`
Owns the `DatabasePool` for a single account. Created/destroyed on account add/remove.

```swift
final class MailDatabase: Sendable {
    let dbPool: DatabasePool

    init(accountID: String) throws {
        let path = Self.databasePath(for: accountID)
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA cache_size = -64000")
        }
        #if DEBUG
        config.prepareDatabase { db in
            db.trace { print($0) }
        }
        #endif
        dbPool = try DatabasePool(path: path, configuration: config)
        try Self.migrator.migrate(dbPool)
    }

    /// Check database integrity on launch. If corrupt, delete and re-sync.
    func integrityCheck() throws -> Bool {
        try dbPool.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            return result == "ok"
        }
    }
}
```

#### Database Corruption Recovery

If `integrityCheck()` fails on launch:
1. Close the `DatabasePool`
2. Delete the database file (and `-wal`, `-shm` files)
3. Re-create `MailDatabase` (empty)
4. Trigger full sync from Gmail API

The database is not authoritative — Gmail is the source of truth. Losing the local DB means a temporary performance regression (re-sync) but no data loss.

#### `BackgroundSyncer` (actor)
Handles bulk writes and API sync operations.

```swift
actor BackgroundSyncer {
    let db: MailDatabase
    let apiClient: GmailAPIClient
    let messageService: GmailMessageService

    /// Sync inbox: list message IDs → upsert metadata → queue body pre-fetch
    func syncFolder(labelIDs: [String], query: String?) async throws -> SyncResult

    /// Apply history delta (incremental sync)
    func applyHistoryDelta(startHistoryId: String, labelId: String?) async throws -> DeltaResult

    /// Pre-fetch full bodies for messages that only have metadata
    func preFetchBodies(priority: PreFetchPriority) async throws

    /// Sync contacts from People API
    func syncContacts() async throws

    /// Upsert labels from API
    func syncLabels() async throws
}
```

#### Record Types
GRDB records bridge between SQLite and Swift. They are Codable value types, not reference types.

```swift
struct MessageRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"

    var gmailId: String        // maps to gmail_id (primary key)
    var threadId: String
    var historyId: String?
    var internalDate: Double   // Unix timestamp
    var snippet: String?
    var sizeEstimate: Int?
    var subject: String?
    var senderEmail: String?
    var senderName: String?
    var toRecipients: String?  // JSON
    var ccRecipients: String?  // JSON
    var bccRecipients: String? // JSON
    var replyTo: String?
    var messageIdHeader: String?
    var inReplyTo: String?
    var bodyHtml: String?
    var bodyPlain: String?
    var rawHeaders: String?    // JSON
    var hasAttachments: Bool
    var isRead: Bool
    var isStarred: Bool
    var isFromMailingList: Bool
    var unsubscribeUrl: String?
    var fullBodyFetched: Bool
    var threadMessageCount: Int
    var fetchedAt: Double?

    var id: String { gmailId }

    // Convert from Gmail API model
    init(from gmail: GmailMessage) { ... }

    // Convert to UI Email model
    func toEmail(labels: [LabelRecord], tags: EmailTagRecord?) -> Email { ... }
}
```

### Data Flows

#### App Launch → Inbox Appears

```
1. MailDatabase.init(accountID) — open/create SQLite DB
   └─ integrityCheck() — if corrupt, delete + recreate
2. UI subscribes: @FetchAll(MessageRecord.inbox()) → instant render from DB
3. BackgroundSyncer.syncFolder(labelIDs: ["INBOX"])
   a. API: messages.list → get message IDs
   b. Filter: which IDs are NOT in DB?
   c. API: batchFetch missing message metadata
   d. DB: upsert new messages + update message_labels (single write transaction)
   e. ValueObservation fires → UI auto-updates with new messages
4. BackgroundSyncer.preFetchBodies(priority: .visible)
   a. Query: messages WHERE full_body_fetched = 0 ORDER BY internal_date DESC
   b. API: batchFetch full format (3 concurrent batches of 50)
   c. DB: UPDATE messages SET body_html=?, body_plain=?, full_body_fetched=1
   d. UPDATE messages_fts with body_plain content
   e. Silent — no UI change needed (content ready for when user clicks)
```

**First launch timing:**
- Step 2: <5ms (empty DB, but no spinner — just empty list)
- Step 3: 1-3s (API fetch + bulk upsert)
- Step 4: runs continuously in background, newest first

**Subsequent launches:**
- Step 2: <5ms (full inbox from DB — instant)
- Step 3: 100-500ms (delta sync via History API)
- Step 4: only new messages need bodies

#### Click Email → Thread Detail (instant)

```
1. UI: user taps email row
2. Query: SELECT * FROM messages WHERE thread_id = ? ORDER BY internal_date ASC
   → Returns all messages in thread with full HTML bodies (<5ms)
3. If all messages have full_body_fetched = 1:
   → Render immediately, no spinner
4. If any message has full_body_fetched = 0:
   → Render what we have (metadata + snippet)
   → Background: fetch missing bodies → DB update → ValueObservation → UI refreshes
5. Background: check for newer messages in thread (API) → upsert if found
```

**Typical timing:** <5ms for cached threads (the common case after background pre-fetch).

#### Folder Switch

```
1. UI query changes: @FetchAll(MessageRecord.forFolder(labelIDs))
2. GRDB serves from DB instantly (<5ms) — no disk re-read, no API call
3. Background: delta sync for this folder → upsert changes → UI auto-updates
```

No folder switch penalty — all messages are in the same database, queries just filter by label.

#### Pull to Refresh / Timer (120s)

```
1. BackgroundSyncer.applyHistoryDelta(startHistoryId, labelId)
   a. API: history.list → messages added/deleted/label-changed
   b. DB: INSERT new, DELETE removed, UPDATE labels + denormalized columns
   c. ValueObservation fires → UI animates changes
2. If history expired (404): fall back to full syncFolder()
3. BackgroundSyncer.preFetchBodies() — queue any new messages
```

**Note:** Gmail's `history.list` returns HTTP 404 (not 410) when `startHistoryId` is no longer valid. This matches the existing `HistorySyncService` behavior.

#### Search

```
1. User types query in search bar
2. FTS5 query:
   SELECT m.* FROM messages m
   JOIN messages_fts fts ON m.gmail_id = fts.gmail_id
   WHERE messages_fts MATCH ?
   ORDER BY rank
3. Results in <50ms for 100K+ messages (FTS5 indexed)
4. If query matches no FTS results, optionally fall back to API search
   for messages not yet in DB
```

#### Optimistic UI Updates (direct writes)

```
User stars a message:
1. MailboxViewModel calls dbPool.write { db in
     try db.execute(sql: "UPDATE messages SET is_starred = 1 WHERE gmail_id = ?", arguments: [id])
     try db.execute(sql: "INSERT OR IGNORE INTO message_labels (message_id, label_id) VALUES (?, 'STARRED')", arguments: [id])
   }
   → <1ms, UI updates via ValueObservation
2. Async: GmailMessageService.setStarred(id, accountID) — fire API call
3. If API fails: revert DB write
```

---

## Migration Strategy

### Phase 1: Add Database (non-breaking, parallel operation)

**Changes:**
- Add GRDB + SharingGRDB Swift Package dependencies
- Create `MailDatabase`, record types, migrations
- Create `BackgroundSyncer` actor
- On app launch: if DB empty, populate from existing JSON cache (one-time migration)
- Both JSON cache and DB active; **DB is written first, JSON is read-only fallback**

**Consistency contract:** During Phase 1, the DB is always the first write target. The JSON cache continues to be written as a read-through fallback but is never the source of truth. If DB and JSON disagree, DB wins. This prevents split-brain issues during the transition.

**Risk:** Low. No existing behavior changes. DB populates silently.

### Phase 2: Switch Reads to Database

**Changes:**
- `MailboxViewModel` reads from DB via `@FetchAll` / `ValueObservation` instead of `MessageFetchService`
- Thread detail reads from DB instead of `MailCacheStore.loadThread()`
- Label counts from `SELECT COUNT(*) FROM message_labels WHERE label_id = ?`
- Contact photo URLs from `contacts` table (survives restart)
- Search uses FTS5 instead of API `q=` parameter
- Inject `DatabaseContext` into SwiftUI environment, swapping on account change

**Removes:**
- `MessageFetchService.messageCache` (in-memory dictionary)
- `MessageFetchService.allCachedMessages` (in-memory array)
- `MessageFetchService.localOffset` (pagination cursor — replaced by DB query with LIMIT/OFFSET)
- JSON cache writes (stop writing, keep reading as fallback)

### Phase 3: Remove Old Cache

**Removes:**
- `MailCacheStore` (entire file — JSON disk cache)
- `MessageFetchService` (replaced by DB queries + BackgroundSyncer)
- `ContactStore` (UserDefaults → DB `contacts` table)
- `ContactPhotoCache` (in-memory → DB `contacts.photo_url`)
- `AttachmentDatabase` (standalone SQLite → merged into `MailDatabase`)
- JSON cache files on disk (one-time cleanup)
- `_tags.json` → `email_tags` table
- `_labels.json` → `labels` table

**Keeps (unchanged):**
- All Gmail API service classes
- `GmailAPIClient` (HTTP layer)
- `OfflineActionQueue` (file-based, small data, independent concern)
- `SnoozeStore` / `ScheduledSendStore` (file-based, small data)
- `AvatarCache` (disk image cache — separate from metadata)
- `TokenStore` (Keychain)
- `AccountStore` (UserDefaults — lightweight account metadata)
- All SwiftUI views (consume same `Email` model)
- `HistorySyncService` (logic reused inside `BackgroundSyncer`)

---

## API Best Practices (bundled improvements)

| Improvement | Detail |
|---|---|
| **ETag conditional requests** | Store ETags for labels in `account_sync_state`. Send `If-None-Match` header. On 304: skip parse/write. |
| **Gzip compression** | Add explicit `Accept-Encoding: gzip` header and ensure User-Agent contains "gzip" substring on all requests. |
| **Batch upsert on sync** | Wrap all message upserts in a single `dbPool.write { }` transaction. Use GRDB's `upsert()` for insert-or-update semantics. |
| **Background body pre-fetch** | After metadata sync, query `messages WHERE full_body_fetched = 0` ordered by date DESC. Fetch full format in batches of 50, 3 concurrent. Bounded by rate limits. |
| **Contact photo persistence** | Photo URLs stored in `contacts` table. Survives restart. AvatarCache (image files) unchanged. |
| **Label counts from DB** | `SELECT COUNT(*) FROM message_labels WHERE label_id = ?` replaces per-label API calls. |
| **Classifier versioning** | `email_tags.classifier_version` enables re-classification when AI model updates. |

---

## Body Eviction Policy

To manage disk usage, full message bodies are kept for a configurable window (default: 6 months). Older messages retain metadata + snippet but have `body_html`/`body_plain` set to NULL and `full_body_fetched` reset to 0.

**Eviction trigger:** Background task on app launch, runs after initial sync completes.

**Eviction query (runs in a single transaction):**
```sql
-- Step 1: Collect affected gmail_ids
-- Step 2: Update FTS (DELETE + re-INSERT without body_plain) for each affected row
-- Step 3: Null out bodies
UPDATE messages
SET body_html = NULL, body_plain = NULL, full_body_fetched = 0
WHERE internal_date < ? AND full_body_fetched = 1
```

All three steps run inside a single `dbPool.write { }` transaction to avoid a window where `full_body_fetched = 0` but FTS still has stale body text. FTS cleanup uses the centralized `updateFTSIndex(for:in:)` method.

**On-demand re-fetch:** When a user opens an evicted thread, the missing bodies are fetched from the API and re-inserted (same as the "body not yet fetched" path in thread detail flow).

**Configurable:** `UserDefaults` key `bodyRetentionMonths` (default 6). Setting to 0 means keep all bodies indefinitely.

---

## Performance Characteristics

| Operation | Current | After GRDB |
|---|---|---|
| Thread open (first time) | 500-1500ms (API) | <5ms (DB) after background pre-fetch |
| Thread open (cached) | 50-200ms (JSON disk read) | <5ms (DB, indexed query) |
| Folder switch | 200-500ms (JSON read + API) | <5ms (DB query, different WHERE clause) |
| Inbox load on launch | 50ms (JSON) + 1-2s (API) | <5ms (DB) + background delta sync |
| Search | 1-3s (API, server-side) | <50ms (FTS5, local) |
| Label unread count | 200-500ms (API per label) | <1ms (COUNT query) |
| Mark as read | Instant (optimistic) | Instant (direct DB write, <1ms) |
| Star/archive | Instant (optimistic) | Instant (direct DB write, <1ms) |
| Background sync | N/A | 100-500ms every 120s (delta) |

---

## Disk Usage Estimates

| Data | Estimated Size (per account) |
|---|---|
| 10K messages (metadata only) | ~50 MB |
| 10K messages (full bodies) | ~200-500 MB |
| 100K messages (metadata only) | ~500 MB |
| 100K messages (full bodies) | ~2-5 GB |
| FTS5 index | ~20-50% of text content |
| Labels + contacts + tags | <1 MB |

**Mitigation:** Body eviction policy (see above) — keep full bodies for most recent N months (configurable), evict older bodies (re-fetch on demand). Metadata always kept.

---

## Open Questions

1. **How many months of full message bodies to keep?** Suggest 6 months default, configurable in settings. Older messages keep metadata + snippet, body fetched on demand.
2. **Initial full sync depth** — how far back on first login? Suggest 3 months of metadata, then background sync older messages progressively.
3. **Attachment content storage** — store downloaded attachment binary data in DB or keep as separate files? Suggest separate files (current approach) to avoid bloating the DB.
4. **SharingGRDB vs raw ValueObservation** — SharingGRDB is newer/simpler but adds a dependency. Raw ValueObservation is more flexible. Suggest SharingGRDB for simple list views, ValueObservation for complex queries.
