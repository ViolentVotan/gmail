# Database

Per-account GRDB SQLite persistence layer. Replaces the previous JSON file cache with a local-first architecture: API sync writes to DB via `BackgroundSyncer`, `ValueObservation` reactively updates the UI.

## Guidelines

- One SQLite database per Gmail account at `~/Library/Application Support/com.vikingz.serif.app/mail-db/{accountID}.sqlite`.
- WAL mode with `synchronous = NORMAL` for concurrent reads during writes.
- All record types use snake_case column mapping (`databaseColumnDecodingStrategy`/`databaseColumnEncodingStrategy`).
- Schema changes go through `MailDatabaseMigrations` — never modify tables outside the migrator.
- FTS5 uses a manual (non-content-sync) virtual table with DELETE-then-INSERT pattern.
- Reads happen via `dbPool.read { }`. Writes go through `BackgroundSyncer` (actor, all methods `async throws` using GRDB async write) for bulk operations, or `dbPool.write { }` for optimistic UI updates.

## Files

### `Database/`

| File | Role |
|------|------|
| `MailDatabase.swift` | `DatabasePool` owner — WAL mode (enabled by `DatabasePool`), `synchronous = NORMAL`, foreign keys, cache size pragmas, integrity check, per-account path, `deleteDatabase(accountID:)`, `evict(accountID:)` (removes a closed account's database from the in-memory instance cache on sign-out), `shared(for:)` instance cache (backed by `Mutex`, double-checked locking: cache lookup under lock, DB creation/migration outside lock, re-check under lock to insert — avoids blocking all threads during migrations) |
| `MailDatabaseMigrations.swift` | `#if DEBUG eraseDatabaseOnSchemaChange = true`. v1 schema: 7 tables (`messages`, `labels`, `message_labels`, `contacts`, `attachments`, `email_tags`, `account_sync_state`), FTS5 virtual table `messages_fts`, 8 indexes. `message_labels.label_id` FK uses `ON DELETE RESTRICT` (prevents silent cascade). Seed INSERT uses `INSERT OR IGNORE` for idempotency. v2: extends `account_sync_state` with sync engine columns. v3: adds `labels_etag` for ETag-based label sync caching. v4: partial index `messages_unread` on `internal_date WHERE is_read = 0` for unread queries; drops redundant `message_labels_message` index (composite PK covers it). v5: recreates `message_labels` with `ON DELETE CASCADE` on both FKs (cleans orphans first, preserves label index); recreates `attachments` with `NOT NULL` on `indexing_status` and `retry_count` (backfills NULLs, uses COALESCE). v6: adds `messages_fts_delete` trigger — `AFTER DELETE ON messages` automatically removes orphaned FTS rows, preventing FTS index divergence on CASCADE deletes. v7: adds `messages_fts_update` trigger — `AFTER UPDATE OF subject, body_plain, snippet, sender_name, sender_email ON messages` keeps FTS in sync on direct column updates (defense-in-depth alongside `FTSManager`). v8: adds `references_header` TEXT column to `messages` table for RFC 2822 References header persistence (used for reply chain construction). |
| `MailDatabaseQueries.swift` | Static read queries: `messagesForLabel`, `messagesForThread`, `unreadCount`, `labels`, `messagesNeedingBodies`, `messagesWithoutBodiesCount`, `messageExists` (uses `MessageRecord.exists()` instead of `fetchOne`), `allContacts` (full table load), `syncState`, `updateSyncState` |
| `FTSManager.swift` | FTS5 maintenance: `index` (DELETE + INSERT), `update` (delegates to `index`), `delete`, `search` (subquery-based: `WHERE gmail_id IN (SELECT ... FROM messages_fts)`) |
| `CacheMigration.swift` | One-time JSON cache → GRDB migration (labels, messages, AI tags). Runs on first launch per account. Completion flag set after cleanup succeeds (not before). Flag cleared on account removal. Tag migration relies on FK constraints to reject orphaned tags (no per-record existence check). |

### `Database/Records/`

All 7 record types conform to `Sendable`.

| File | Role |
|------|------|
| `MessageRecord.swift` | Main record — `init(from: GmailMessage)` uses `GmailMessage.headerMap` for O(1) header lookups (9 headers per message including References), `toGmailMessage()`, `toEmail(labels:tags:)` (delegates folder resolution to `GmailDataTransformer.folderFor(labelIDs:)`), `fixture()` for tests. `referencesHeader` stores the RFC 2822 References header value. Uses `GmailSystemLabel` constants for `isRead`/`isStarred` checks. Contact parsing via `GmailDataTransformer.parseContactCore`. |
| `LabelRecord.swift` | Label record — `init(from: GmailLabel)`, associations to `MessageLabelRecord` |
| `MessageLabelRecord.swift` | Join table record for message ↔ label many-to-many |
| `ContactRecord.swift` | Contact record with photo URL |
| `AttachmentRecord.swift` | Attachment metadata record. `indexingStatus` (default `"pending"`) and `retryCount` (default `0`) are non-optional with defaults. |
| `EmailTagRecord.swift` | AI classification tags (needsReply, fyiOnly, hasDeadline, financial) |
| `AccountSyncStateRecord.swift` | Per-account sync state (contacts sync tokens, history ID, initial sync progress, body prefetch tracking, directory sync token, labels ETag) |

### `Services/BackgroundSyncer.swift`

Actor that centralizes all bulk DB writes. All methods are `async throws` using GRDB's async write API (does not block the actor executor). Shared helpers: `upsertSingleMessage` (DRY extraction used by both upsert and delta paths), `updateThreadCounts` (CTE-based — computes counts once per thread via `GROUP BY`, then batch-updates all affected messages; used by all 3 write paths). FTS always uses unconditional `FTSManager.update` (DELETE + INSERT — safe for new and existing rows):
- `upsertMessages(_:ensureLabels:)` — delegates per-message work to `upsertSingleMessage`; `thread_message_count` via `updateThreadCounts`
- `deleteMessages(gmailIds:)` — removes messages + FTS entries; also calls `AttachmentDatabase.shared.deleteMessages()` for attachment cleanup; `thread_message_count` via `updateThreadCounts`
- `updateBodies(_:)` — writes pre-fetched full bodies + updates FTS
- `upsertLabels(_:)` — bulk label sync (empty-array guard)
- `upsertContacts(_:)` / `deleteContacts(emails:)` — contact CRUD (empty-array guards)
- `upsertContactsWithSyncToken(_:tokenUpdate:accountID:)` — atomic contact upsert + sync token write in a single DB transaction (used by `PeopleAPIService` to prevent token/data skew)
- `applyDelta(newMessages:deletedIds:labelUpdates:)` — delegates per-message work to `upsertSingleMessage`; `thread_message_count` via `updateThreadCounts`; calls `AttachmentDatabase.shared.deleteMessages()` for deleted IDs

## Data Flow

```
Gmail API → FullSyncEngine (orchestrates all sync: initial, incremental, body prefetch)
         → BackgroundSyncer (writes to GRDB)
         → ValueObservation fires (MailboxViewModel)
         → emails property updates → SwiftUI re-renders
```

## Key Patterns

- **ValueObservation**: `MailboxViewModel.startObservingLabel(_:)` uses `ValueObservation.tracking` (not `trackingConstantRegion` — the JOIN through `message_labels` means the tracked region varies with the label filter) with async `for try await` values API for guaranteed MainActor delivery. Fires immediately with current data, then on every DB change.
- **DB identity check**: `handleDatabaseUpdate` guards with `db === mailDatabase` to prevent cross-account races.
- **Nonisolated enrichment**: `enrichRecords` is a `nonisolated static func` to avoid blocking MainActor during DB reads.
- **Body preservation**: Metadata-only syncs (no body content) write records without overwriting previously-fetched bodies.
- **FTS5 search**: `MailboxViewModel.search()` queries FTS locally.
- **Optimistic mutations**: All email mutations (read, star, archive, trash, spam) write to DB first → ValueObservation updates UI → API call → revert on failure. `writeLabels` and `applyReadLocally` in `MailboxViewModel` use `async` (`try await dbPool.write`).
