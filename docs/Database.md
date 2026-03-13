# Database

Per-account GRDB SQLite persistence layer. Replaces the previous JSON file cache with a local-first architecture: API sync writes to DB via `BackgroundSyncer`, `ValueObservation` reactively updates the UI.

## Guidelines

- One SQLite database per Gmail account at `~/Library/Application Support/com.genyus.serif.app/mail-db/{accountID}.sqlite`.
- WAL mode with `synchronous = NORMAL` for concurrent reads during writes.
- All record types use snake_case column mapping (`databaseColumnDecodingStrategy`/`databaseColumnEncodingStrategy`).
- Schema changes go through `MailDatabaseMigrations` — never modify tables outside the migrator.
- FTS5 uses a manual (non-content-sync) virtual table with DELETE-then-INSERT pattern.
- Reads happen via `dbPool.read { }`. Writes go through `BackgroundSyncer` (actor) for bulk operations, or `dbPool.write { }` for optimistic UI updates.

## Files

### `Database/`

| File | Role |
|------|------|
| `MailDatabase.swift` | `DatabasePool` owner — WAL pragmas, foreign keys, cache size, integrity check, per-account path, `deleteDatabase(accountID:)`, `shared(for:)` instance cache |
| `MailDatabaseMigrations.swift` | v1 schema: 8 tables (`messages`, `labels`, `message_labels`, `contacts`, `attachments`, `email_tags`, `folder_sync_state`, `account_sync_state`), FTS5 virtual table `messages_fts`, 8 indexes |
| `MailDatabaseQueries.swift` | Static read queries: `messagesForLabel`, `messagesForThread`, `unreadCount`, `labels`, `messagesNeedingBodies`, `messageExists`, `allContacts`, `contactCount`, `syncState`, `updateSyncState` |
| `FTSManager.swift` | FTS5 maintenance: `index`, `update`, `delete`, `evictBody`, `indexBatch`, `search` |
| `CacheMigration.swift` | One-time JSON cache → GRDB migration (labels, messages, AI tags). Runs on first launch per account. |

### `Database/Records/`

| File | Role |
|------|------|
| `MessageRecord.swift` | Main record — `init(from: GmailMessage)`, `toGmailMessage()`, `toEmail(labels:tags:)`, `fixture()` for tests |
| `LabelRecord.swift` | Label record — `init(from: GmailLabel)`, associations to `MessageLabelRecord` |
| `MessageLabelRecord.swift` | Join table record for message ↔ label many-to-many |
| `ContactRecord.swift` | Contact record with photo URL |
| `AttachmentRecord.swift` | Attachment metadata record |
| `EmailTagRecord.swift` | AI classification tags (needsReply, fyiOnly, hasDeadline, financial) |
| `FolderSyncStateRecord.swift` | Per-folder sync state (historyId, nextPageToken) |
| `AccountSyncStateRecord.swift` | Per-account sync state (contacts sync tokens, labels etag) |

### `Services/BackgroundSyncer.swift`

Actor that centralizes all bulk DB writes:
- `upsertMessages(_:ensureLabels:)` — upserts messages + labels + join table + FTS
- `deleteMessages(gmailIds:)` — removes messages + FTS entries
- `updateBodies(_:)` — writes pre-fetched full bodies + updates FTS
- `upsertLabels(_:)` — bulk label sync
- `upsertContacts(_:)` / `deleteContacts(emails:)` / `deleteAllContacts()` — contact CRUD
- `applyDelta(newMessages:deletedIds:labelUpdates:)` — history delta sync
- `preFetchBodies(messageService:accountID:)` — background body download
- `evictBodies(olderThan:)` — reclaims disk space for old message bodies

## Data Flow

```
Gmail API → MessageFetchService (API pagination)
         → BackgroundSyncer (writes to GRDB)
         → ValueObservation fires (MailboxViewModel)
         → emails property updates → SwiftUI re-renders
```

## Key Patterns

- **ValueObservation**: `MailboxViewModel.startObservingLabel(_:)` observes `messagesForLabel` query with default MainActor scheduling (GRDB 7 auto-detects `@MainActor` context). Fires immediately with current data, then on every DB change.
- **DB identity check**: `handleDatabaseUpdate` guards with `db === mailDatabase` to prevent cross-account races.
- **Nonisolated enrichment**: `enrichRecords` is a `nonisolated static func` to avoid blocking MainActor during DB reads.
- **Body preservation**: Metadata-only syncs (no body content) write records without overwriting previously-fetched bodies.
- **FTS5 search**: `MailboxViewModel.search()` queries FTS locally first, falls back to Gmail API for broader results.
