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
| `MailDatabase.swift` | `DatabasePool` owner — WAL pragmas, foreign keys, cache size, integrity check, per-account path, `deleteDatabase(accountID:)`, `shared(for:)` instance cache (backed by `Mutex`, not `NSLock`) |
| `MailDatabaseMigrations.swift` | `#if DEBUG eraseDatabaseOnSchemaChange = true`. v1 schema: 7 tables (`messages`, `labels`, `message_labels`, `contacts`, `attachments`, `email_tags`, `account_sync_state`), FTS5 virtual table `messages_fts`, 8 indexes. `message_labels.label_id` FK uses `ON DELETE RESTRICT` (prevents silent cascade). Seed INSERT uses `INSERT OR IGNORE` for idempotency. v2: extends `account_sync_state` with sync engine columns. v3: adds `labels_etag` for ETag-based label sync caching. v4: partial index `messages_unread` on `internal_date WHERE is_read = 0` for unread queries; drops redundant `message_labels_message` index (composite PK covers it). |
| `MailDatabaseQueries.swift` | Static read queries: `messagesForLabel`, `messagesForThread`, `unreadCount`, `labels`, `messagesNeedingBodies`, `messagesWithoutBodiesCount`, `messageExists` (uses `MessageRecord.exists()` instead of `fetchOne`), `allContacts` (full table load), `syncState`, `updateSyncState` |
| `FTSManager.swift` | FTS5 maintenance: `index`, `update`, `delete`, `indexBatch`, `search` (JOIN-based query for relevance ordering) |
| `CacheMigration.swift` | One-time JSON cache → GRDB migration (labels, messages, AI tags). Runs on first launch per account. Completion flag set after cleanup succeeds (not before). Flag cleared on account removal. Tag migration performs per-record FK check (`MessageRecord.exists`) to skip orphaned tags. |

### `Database/Records/`

| File | Role |
|------|------|
| `MessageRecord.swift` | Main record — `init(from: GmailMessage)`, `toGmailMessage()`, `toEmail(labels:tags:)` (delegates folder resolution to `GmailDataTransformer.folderFor(labelIDs:)`), `fixture()` for tests |
| `LabelRecord.swift` | Label record — `init(from: GmailLabel)`, associations to `MessageLabelRecord` |
| `MessageLabelRecord.swift` | Join table record for message ↔ label many-to-many |
| `ContactRecord.swift` | Contact record with photo URL |
| `AttachmentRecord.swift` | Attachment metadata record |
| `EmailTagRecord.swift` | AI classification tags (needsReply, fyiOnly, hasDeadline, financial) |
| `AccountSyncStateRecord.swift` | Per-account sync state (contacts sync tokens, history ID, initial sync progress, body prefetch tracking, directory sync token, labels ETag) |

### `Services/BackgroundSyncer.swift`

Actor that centralizes all bulk DB writes. All methods are `async throws` using GRDB's async write API (does not block the actor executor):
- `upsertMessages(_:ensureLabels:)` — upserts messages + labels + join table + FTS; uses a batch `SELECT gmail_id IN (...)` into a `Set<String>` to check existence; empty-array guard prevents `IN ()` syntax error; attachments use `upsert` for concurrent writer safety; `thread_message_count` updated via set-based `UPDATE` (single SQL, not per-thread loop)
- `deleteMessages(gmailIds:)` — removes messages + FTS entries; updates `thread_message_count` via set-based `UPDATE`
- `updateBodies(_:)` — writes pre-fetched full bodies + updates FTS
- `upsertLabels(_:)` — bulk label sync (empty-array guard)
- `upsertContacts(_:)` / `deleteContacts(emails:)` — contact CRUD (empty-array guards)
- `applyDelta(newMessages:deletedIds:labelUpdates:)` — history delta sync; attachments use `upsert`; set-based `thread_message_count` update

## Data Flow

```
Gmail API → FullSyncEngine (orchestrates all sync: initial, incremental, body prefetch)
         → BackgroundSyncer (writes to GRDB)
         → ValueObservation fires (MailboxViewModel)
         → emails property updates → SwiftUI re-renders
```

## Key Patterns

- **ValueObservation**: `MailboxViewModel.startObservingLabel(_:)` uses `ValueObservation.trackingConstantRegion` (tracked tables computed once) with async `for try await` values API for guaranteed MainActor delivery. Fires immediately with current data, then on every DB change.
- **DB identity check**: `handleDatabaseUpdate` guards with `db === mailDatabase` to prevent cross-account races.
- **Nonisolated enrichment**: `enrichRecords` is a `nonisolated static func` to avoid blocking MainActor during DB reads.
- **Body preservation**: Metadata-only syncs (no body content) write records without overwriting previously-fetched bodies.
- **FTS5 search**: `MailboxViewModel.search()` queries FTS locally.
- **Optimistic mutations**: All email mutations (read, star, archive, trash, spam) write to DB first → ValueObservation updates UI → API call → revert on failure.
