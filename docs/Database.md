# Database

Per-account GRDB SQLite persistence layer. Replaces the previous JSON file cache with a local-first architecture: API sync writes to DB via `BackgroundSyncer`, `ValueObservation` reactively updates the UI.

## Guidelines

- One SQLite database per Gmail account at `~/Library/Application Support/com.vikingz.serif.app/mail-db/{accountID}.sqlite`.
- WAL mode with `synchronous = NORMAL` for concurrent reads during writes.
- All record types use snake_case column mapping (`databaseColumnDecodingStrategy`/`databaseColumnEncodingStrategy`).
- Schema changes go through `MailDatabaseMigrations` — never modify tables outside the migrator.
- FTS5 uses a manual (non-content-sync) virtual table with DELETE-then-INSERT pattern.
- Reads happen via `dbPool.read { }`. Writes go through `BackgroundSyncer` (actor) for bulk operations, or `dbPool.write { }` for optimistic UI updates.

## Files

### `Database/`

| File | Role |
|------|------|
| `MailDatabase.swift` | `DatabasePool` owner — WAL pragmas, foreign keys, cache size, integrity check, per-account path, `deleteDatabase(accountID:)`, `shared(for:)` instance cache (backed by `Mutex`, not `NSLock`) |
| `MailDatabaseMigrations.swift` | v1 schema: 7 tables (`messages`, `labels`, `message_labels`, `contacts`, `attachments`, `email_tags`, `account_sync_state`), FTS5 virtual table `messages_fts`, 8 indexes. v2 migration: extends `account_sync_state` with sync engine columns (`last_history_id`, `initial_sync_complete`, `initial_sync_page_token`, `synced_message_count`, `total_messages_estimate`, `last_sync_at`, `last_body_prefetch_at`, `directory_sync_token`), drops legacy `folder_sync_state`. v3 migration: adds `labels_etag` to `account_sync_state` for ETag-based label sync caching. |
| `MailDatabaseQueries.swift` | Static read queries: `messagesForLabel`, `messagesForThread`, `unreadCount`, `labels`, `messagesNeedingBodies`, `messagesWithoutBodiesCount`, `totalMessageCount`, `messageExists` (uses `MessageRecord.exists()` instead of `fetchOne`), `allContacts`, `contactCount`, `syncState`, `updateSyncState` |
| `FTSManager.swift` | FTS5 maintenance: `index`, `update`, `delete`, `evictBody`, `indexBatch`, `search` |
| `CacheMigration.swift` | One-time JSON cache → GRDB migration (labels, messages, AI tags). Runs on first launch per account. Tag migration performs per-record FK check (`MessageRecord.exists`) to skip orphaned tags. |

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

Actor that centralizes all bulk DB writes:
- `upsertMessages(_:ensureLabels:)` — upserts messages + labels + join table + FTS; uses a batch `SELECT gmail_id IN (...)` into a `Set<String>` to check existence instead of per-record `MessageRecord.exists()` calls
- `deleteMessages(gmailIds:)` — removes messages + FTS entries; updates `thread_message_count` on remaining messages in affected threads
- `updateBodies(_:)` — writes pre-fetched full bodies + updates FTS
- `upsertLabels(_:)` — bulk label sync
- `upsertContacts(_:)` / `deleteContacts(emails:)` — contact CRUD
- `applyDelta(newMessages:deletedIds:labelUpdates:)` — history delta sync

## Data Flow

```
Gmail API → FullSyncEngine (orchestrates all sync: initial, incremental, body prefetch)
         → BackgroundSyncer (writes to GRDB)
         → ValueObservation fires (MailboxViewModel)
         → emails property updates → SwiftUI re-renders
```

## Key Patterns

- **ValueObservation**: `MailboxViewModel.startObservingLabel(_:)` observes `messagesForLabel` query with default MainActor scheduling (GRDB 7 auto-detects `@MainActor` context). Fires immediately with current data, then on every DB change.
- **DB identity check**: `handleDatabaseUpdate` guards with `db === mailDatabase` to prevent cross-account races.
- **Nonisolated enrichment**: `enrichRecords` is a `nonisolated static func` to avoid blocking MainActor during DB reads.
- **Body preservation**: Metadata-only syncs (no body content) write records without overwriting previously-fetched bodies.
- **FTS5 search**: `MailboxViewModel.search()` queries FTS locally.
- **Optimistic mutations**: All email mutations (read, star, archive, trash, spam) write to DB first → ValueObservation updates UI → API call → revert on failure.
