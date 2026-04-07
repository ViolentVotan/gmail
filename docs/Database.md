# Database

Per-account GRDB SQLite persistence layer. Replaces the previous JSON file cache with a local-first architecture: API sync writes to DB via `BackgroundSyncer`, `ValueObservation` reactively updates the UI.

## Guidelines

- One SQLite database per Gmail account at `~/Library/Application Support/com.vikingz.vik.app/mail-db/{accountID}.sqlite`.
- WAL mode with `synchronous = NORMAL` for concurrent reads during writes.
- All record types use snake_case column mapping (`databaseColumnDecodingStrategy`/`databaseColumnEncodingStrategy`).
- Schema changes go through `MailDatabaseMigrations` — never modify tables outside the migrator.
- FTS5 uses a manual (non-content-sync) virtual table with DELETE-then-INSERT pattern.
- Reads happen via `dbPool.read { }`. Writes go through `BackgroundSyncer` (actor, all methods `async throws` using GRDB async write) for bulk operations, or `dbPool.write { }` for optimistic UI updates.

## Files

### `Database/`

| File | Role |
|------|------|
| `MailDatabase.swift` | `DatabasePool` owner — WAL mode (enabled by `DatabasePool`), `synchronous = NORMAL`, foreign keys, cache size pragmas, `PRAGMA wal_autocheckpoint = 400` (checkpoints every ~1.6 MB to prevent unbounded WAL growth), `PRAGMA optimize` on open (maintains index statistics without manual ANALYZE), integrity check, per-account path, `close()` runs `PRAGMA wal_checkpoint(TRUNCATE)` before releasing connections (reclaims WAL disk space on shutdown), `deleteDatabase(accountID:)`, `evict(accountID:)` (removes a closed account's database from the in-memory instance cache on sign-out), `shared(for:)` instance cache (backed by `Mutex`: cache lookup under lock, DB creation + migration outside lock, re-check under lock to insert — migrates before caching to prevent concurrent callers from receiving an un-migrated instance; migration failures are NOT permanently cached — callers can retry on transient errors like disk-full) |
| `MailDatabaseMigrations.swift` | `eraseDatabaseOnSchemaChange` is **not used** — database is preserved across schema changes in all builds (use Settings → Advanced → "Delete Local Database" to reset during development). v1 schema: 7 tables (`messages`, `labels`, `message_labels`, `contacts`, `attachments`, `email_tags`, `account_sync_state`), FTS5 virtual table `messages_fts`, 8 indexes. `message_labels.label_id` FK uses `ON DELETE RESTRICT` (prevents silent cascade). Seed INSERT uses `INSERT OR IGNORE` for idempotency. v2: extends `account_sync_state` with sync engine columns. v3: adds `labels_etag` for ETag-based label sync caching. v4: partial index `messages_unread` on `internal_date WHERE is_read = 0` for unread queries; drops redundant `message_labels_message` index (composite PK covers it). v5: recreates `message_labels` with `ON DELETE CASCADE` on both FKs (cleans orphans first, preserves label index); recreates `attachments` with `NOT NULL` on `indexing_status` and `retry_count` (backfills NULLs, uses COALESCE). v6: adds `messages_fts_delete` trigger — `AFTER DELETE ON messages` automatically removes orphaned FTS rows, preventing FTS index divergence on CASCADE deletes. v7: adds `messages_fts_update` trigger — `AFTER UPDATE OF subject, body_plain, snippet, sender_name, sender_email ON messages` keeps FTS in sync on direct column updates (defense-in-depth; later dropped in v11). v8: adds `references_header` TEXT column to `messages` table for RFC 2822 References header persistence (used for reply chain construction). v9: adds `contacts_sync_token_at` and `other_contacts_sync_token_at` timestamp columns to `account_sync_state` for proactive sync token expiry detection (6-day threshold vs Google's 7-day TTL). v10: adds `messages_read_state` index on `(gmail_id, is_read)` for unread count joins, `message_labels_label_message` composite index on `(label_id, message_id)` for category unread counts, and `gmail_draft_id TEXT` column to `messages` for storing the Gmail draft resource ID (distinct from `gmail_id` message ID — required by `drafts/send` API). v11: drops `messages_fts_update` trigger (doubled FTS work on every update; FTS indexing later moved fully to SQL triggers in v20/v21) and drops the superseded `message_labels_label` single-column index (fully covered by the composite `message_labels_label_message` from v10). v13 (Calendar): creates `calendars`, `calendar_events`, and `calendar_attendees` tables (see Calendar Records below). 7 indexes: on `accountId` (calendars, events), time range `(startTime, endTime)`, recurring flag `(isRecurring)`, `iCalUID`, and attendee `email`. **V16** — Replaces `messages_prefetch` index to include `body_fetch_attempts` column for efficient body pre-fetch queries. **V17** — Adds `attachment_count INTEGER NOT NULL DEFAULT 0` to `messages` table; backfills from `attachments` table for existing rows where `has_attachments = 1`. **V18** — Adds `calendar_list_sync_token` TEXT to `account_sync_state`; creates `messages_sender_nocase` index with NOCASE collation for `pruneStaleMessageContacts`. **V19** — Adds HTML preprocessing columns to `messages`: `preprocessed_html`, `sanitized_html`, `original_html`, `quoted_html`, `preprocessing_version`. **V20** — Adds `messages_fts_insert` AFTER INSERT trigger for automatic FTS indexing (skips rows with no searchable content). **V21** — Recreates `messages_fts_insert` trigger with DELETE-before-INSERT dedup to prevent duplicate FTS rows. **V22** — Adds partial index `idx_events_active_account_time` on `calendar_events(account_id, start_time, end_time) WHERE status != 'cancelled'` for fast active-event queries. |
| `MailDatabaseQueries.swift` | Static queries. Reads: `messagesForLabel`, `messagesForThread` (default limit 200), `unreadCount`, `labels`, `messagesNeedingBodies` (excludes SPAM/TRASH; shared `messagesWithoutBodiesSQL` fragment with `messagesWithoutBodiesCount`), `messagesWithoutBodiesCount`, `messageCountForLabel` (for lazy folder loading), `messageExists` (uses `MessageRecord.exists()` instead of `fetchOne`), `allContacts` (optional `limit`), `syncState`, `updateSyncState`, `pruneStaleMessageContacts`. Calendar reads: `calendars`, `visibleCalendars`, `allVisibleCalendars`, `eventsForDateRange` (default limit 1000), `eventsForToday` (default limit 50), `upcomingEventsWithParticipant`, `calendarSyncToken`. Calendar writes: `deleteCalendarEvent`, `updateCalendarEventRSVP` (centralized composite-key SQL for CalendarBackgroundSyncer). Mutations: `updateCalendarVisibility`, `updateCalendarSyncToken`. |
| `CacheMigration.swift` | One-time JSON cache → GRDB migration (labels, messages, AI tags). Runs on first launch per account. `migrateTags` is `async throws` — tag migration failure is logged but does not block cleanup or completion flag (tags are optional). Completion flag set after cleanup succeeds (not before). Flag cleared on account removal. Tag migration relies on FK constraints to reject orphaned tags (no per-record existence check). |

### `Database/Records/`

All 7 record types conform to `Sendable`.

| File | Role |
|------|------|
| `MessageRecord.swift` | Main record — `init(from: GmailMessage)` uses `GmailMessage.headerMap` for O(1) header lookups (9 headers per message including References), `toGmailMessage()`, `toEmail(labels:tags:attachments:)` (delegates folder resolution to `GmailDataTransformer.folderFor(labelIDs:)`), `fixture()` for tests. `referencesHeader` stores the RFC 2822 References header value. `gmailDraftId` stores the Gmail draft resource ID (populated by `MailStore.syncGmailDrafts`; preserved by `BackgroundSyncer.upsertSingleMessage` on metadata-only updates). `attachmentCount` (v17) stores the number of non-inline attachments (populated from `GmailMessage.attachmentParts.count` during sync). Uses `GmailSystemLabel` constants for `isRead`/`isStarred` checks. Contact parsing via `GmailDataTransformer.parseContactCore`. |
| `LabelRecord.swift` | Label record — `init(from: GmailLabel)`, associations to `MessageLabelRecord` |
| `MessageLabelRecord.swift` | Join table record for message ↔ label many-to-many |
| `ContactRecord.swift` | Contact record with photo URL |
| `AttachmentRecord.swift` | Attachment metadata record. `indexingStatus` (default `"pending"`) and `retryCount` (default `0`) are non-optional with defaults. |
| `EmailTagRecord.swift` | AI classification tags (needsReply, fyiOnly, hasDeadline, financial) |
| `AccountSyncStateRecord.swift` | Per-account sync state (contacts sync tokens with acquisition timestamps for proactive expiry, history ID, initial sync progress, body prefetch tracking, directory sync token, labels ETag) |

### Calendar Records

Three additional record types (all `Sendable`) added in migration v13:

| Record | PK | Key fields |
|--------|----|------------|
| `CalendarRecord` | composite `(calendarId, accountId)` | `summary`, `description`, `timeZone`, `backgroundColor`, `foregroundColor`, `isPrimary`, `accessRole`, `isVisible`, `summaryOverride`, `syncToken`, `lastSyncedAt` |
| `CalendarEventRecord` | composite `(eventId, calendarId, accountId)` | `summary`, `startTime`/`endTime` (Unix timestamps), `status`, `organizer`, `selfResponseStatus`, `colorId`, `isRecurring`, `iCalUID`, `conferenceLink`, `etag`, `remindersJson`/`attachmentsJson` (JSON-encoded blobs), 30+ fields total. FK `ON DELETE CASCADE` to `calendars`. |
| `CalendarAttendeeRecord` | composite `(eventId, calendarId, accountId, email)` | `displayName`, `responseStatus`, `isOrganizer`, `isResource`, `isOptional`. FK `ON DELETE CASCADE` to `calendar_events`. |

`CalendarBackgroundSyncer` (actor in `Services/Calendar/`) handles all bulk writes: `upsertCalendars`, `deleteCalendars`, `upsertEvents` (cascades attendee upsert in the same write transaction), `deleteEvents`, `updateSyncToken`. Also handles optimistic UI writes: `optimisticDeleteEvent` (snapshot + delete, returns record for rollback), `rollbackDeleteEvent`, `optimisticUpdateRSVP`, `rollbackRSVP` — all use centralized `MailDatabaseQueries` methods.

Calendar queries in `MailDatabaseQueries`: `calendars`, `visibleCalendars`, `allVisibleCalendars`, `eventsForDateRange` (default limit 1000), `eventsForToday` (default limit 50), `upcomingEventsWithParticipant`, `updateCalendarVisibility`, `calendarSyncToken`, `updateCalendarSyncToken`, `deleteCalendarEvent`, `updateCalendarEventRSVP`.

### `Services/BackgroundSyncer.swift`

Actor that centralizes all bulk DB writes. All methods are `async throws` using GRDB's async write API (does not block the actor executor). Shared helpers: `upsertSingleMessage` (DRY extraction used by both upsert and delta paths). Thread count updates use `MailDatabaseQueries.updateThreadCounts(for:in:)` (CTE-based — computes counts once per thread via `GROUP BY`, then batch-updates all affected messages; shared across BackgroundSyncer and MailboxViewModel). FTS insert indexing is handled by the `messages_fts_insert` SQL trigger (v21 — DELETE-before-INSERT dedup); delete cleanup by the `messages_fts_delete` trigger (v6); body updates use direct SQL in `updateBodies`:
- `upsertMessages(_:ensureLabels:)` — batch-prefetches existing label sets in a single query, then delegates per-message work to `upsertSingleMessage`; `thread_message_count` via `MailDatabaseQueries.updateThreadCounts`
- `updateDraftIds(_:)` — populates `gmail_draft_id` on existing message records (mapping from Gmail Drafts API)
- `deleteMessages(gmailIds:)` — removes messages (FTS cleanup handled by v6 trigger); also calls `AttachmentDatabase.shared.deleteMessages()` for attachment cleanup (separate SQLite connection — documented atomicity gap); `thread_message_count` via `MailDatabaseQueries.updateThreadCounts`
- `updateBodies(_:)` — writes pre-fetched full bodies + updates FTS
- `syncLabels(_:)` — atomic label sync: upserts all labels then deletes stale **user** labels in a single write transaction (prevents cascade-deleting `message_labels` for system labels on transient API blips)
- `pruneStaleContacts()` — removes `source = 'message'` contacts with no corresponding messages (called after contact refresh)
- `upsertContacts(_:)` / `deleteContacts(emails:)` — contact CRUD (empty-array guards)
- `upsertContactsWithSyncToken(_:tokenUpdate:accountID:)` — atomic contact upsert + sync token write in a single DB transaction (used by `PeopleAPIService` to prevent token/data skew)
- `applyDelta(newMessages:deletedIds:labelUpdates:)` — delegates per-message work to `upsertSingleMessage`; `thread_message_count` via `MailDatabaseQueries.updateThreadCounts`; calls `AttachmentDatabase.shared.deleteMessages()` for deleted IDs (FTS cleanup handled by v6 trigger)

## Data Flow

```
Gmail API → FullSyncEngine (orchestrates all sync: initial, incremental, body prefetch)
         → BackgroundSyncer (writes to GRDB)
         → ValueObservation fires (MailboxViewModel)
         → emails property updates → SwiftUI re-renders
```

## Key Patterns

- **ValueObservation**: `MailboxViewModel.startObservingLabel(_:)` uses `ValueObservation.tracking` (not `trackingConstantRegion` — the JOIN through `message_labels` means the tracked region varies with the label filter) with async `for try await` values API for guaranteed MainActor delivery. Fires immediately with current data, then on every DB change. A 50ms debounce (`observationDebounceTask`) prevents render storms during rapid bulk writes (e.g. initial sync).
- **DB identity check**: `handleDatabaseUpdate` guards with `db === mailDatabase` to prevent cross-account races.
- **Nonisolated enrichment**: `enrichRecords` is a `nonisolated static func` to avoid blocking MainActor during DB reads.
- **Body preservation**: Metadata-only syncs (no body content) write records without overwriting previously-fetched bodies.
- **FTS5 search**: `MailboxViewModel.search()` queries FTS locally.
- **Optimistic mutations**: All email mutations (read, star, archive, trash, spam) write to DB first → ValueObservation updates UI → API call → revert on failure. `writeLabels` and `applyReadLocally` in `LabelMutationService` (extracted from `MailboxViewModel`) use `async` (`try await dbPool.write`). Calendar optimistic mutations route through `CalendarBackgroundSyncer` for centralized write ownership.
