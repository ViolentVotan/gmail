# Services

Business logic, networking, and side effects. This is the **only** layer that talks to external APIs.

## Guidelines

- Services are **singletons** (`static let shared`) — stateless request handlers, not state containers.
- All API calls go through `GmailAPIClient` which handles auth tokens, rate limiting, and logging.
- Services return raw API models (`GmailMessage`, `GmailLabel`, etc.). They do NOT return UI models. Model types conform to `Sendable`.
- Error handling: throw typed errors (`throws(GmailAPIError)`) up to the ViewModel. Services don't show UI or set observable state.
- Services must be **account-aware**: every method takes `accountID` as parameter.
- **Concurrency**: I/O-bound service methods use `@concurrent` for off-MainActor execution. Default isolation is `MainActor` (approachable concurrency). `UndoActionManager` and `NetworkMonitor` use `@Observable` (not `ObservableObject`).
- No SwiftUI imports in pure service files.

## Subfolders

### `Auth/`
OAuth flow, token storage (Keychain), token refresh, token revocation. `OAuthService` handles the Google OAuth PKCE flow, `revokeToken(token:)` for sign-out revocation via Google's endpoint, and `refreshToken` with `invalid_grant` detection (`OAuthError.tokenRevoked`). `postForm` retries on 5xx and network errors with exponential backoff (up to 3 attempts, `pow(2, attempt)` second delays; 4xx errors are not retried). `TokenStore` persists tokens securely. `AuthToken` is the token value type (`Codable`, `Sendable`) with expiration tracking (60-second pre-refresh buffer).

### `Protocols/`
- `MessageFetching` — Protocol abstracting the Gmail message API surface (`@MainActor`, `Sendable`, typed throws). Methods include `getProfile(accountID:)` for history ID retrieval and `batchModifyLabels(ids:add:remove:accountID:)` for bulk label operations. `GmailMessageService` conforms. Enables testing via mocks (`MockMessageFetching`).

### `Gmail/`
Gmail REST API wrappers. One service per domain:
- `GmailAPIClient` — HTTP layer (auth headers, base URL, per-account token refresh coalescing via unified `refreshAndRetry`, retry with exponential backoff + Retry-After on 429/500/503 capped at 64s, 401 auto-retry on standard and batch requests, generic `batchFetch<T>()` returning `BatchFetchResult<T>` (items + failedIDs) for batch GET operations with `@concurrent fetchSingleBatch`, `requestURL()` for non-Gmail Google APIs, `Logger`-based diagnostics). `request()`/`rawRequest()` are `@concurrent` to avoid unnecessary MainActor hops. `performWithETag` has full retry/backoff matching `perform()` (retries 429/500/502/503/504, respects Retry-After, preserves 304 passthrough). Per-part 429 retry in batch responses via `retryRateLimitedParts` (exponential backoff, max 3 attempts, `var activeToken` updated after 401 refresh for subsequent iterations). `batchFetch` returns failed IDs to callers for retry instead of silently dropping them. `GmailAPIError` includes `dailyLimitExceeded` and `domainPolicy` cases. Batch response parsing strips the `response-` prefix from Content-IDs. `GmailPathBuilder` utility enum provides `queryAllowed` charset (internal), `labelQueryParam`, `sendAsPath`.
- `GmailMessageService` — Messages, threads, mutations (trash, archive, star, labels), History API. Label modifications delegate to a single `modifyLabels` method (returns `fields="id,threadId,labelIds"`); `trashMessage` and `untrashMessage` also use `fields="id,threadId,labelIds"`. `batchModifyLabels(ids:add:remove:accountID:)` applies label changes in batches of 1000 (50 quota units per call). Uses `GmailPathBuilder.queryAllowed` for query parameter encoding. `getMessages` returns `(messages: [GmailMessage], failedIDs: [String])` tuple; format-specific `fields` via `MessageFields` enum (metadata: headers/snippet/labels; full: payload/snippet/labels).
- `GmailLabelService` — Label CRUD
- `GmailProfileService` — Gmail profile info, user identity (OAuth userinfo), send-as aliases, signature management
- `GmailSendService` — Compose, send, draft CRUD (RFC 2822 MIME encoding with RFC 2047 header encoding, base64 Content-Transfer-Encoding for text parts). Outgoing messages include a `Date:` header via a cached `rfc2822Formatter` (`nonisolated static`, `autoupdatingCurrent` timezone). Header construction is extracted into a `nonisolated private static func buildHeaders(...)` reused by both plain and multipart builders.
- `GmailDraftService` — Draft fetch (single + batch via `batchFetch` with format-specific `fields` via `DraftFields` enum); `getDrafts` returns `(drafts: [GmailDraft], failedIDs: [String])` tuple. Used for quick reply draft loading.
- `GmailFilterService` — Gmail filter CRUD (list, create, delete filters)
- `GmailModels` — All API response/request types (`Codable` structs)

### Root-level files
| File | Role |
|------|------|
| `APILogger.swift` | API request/response debug logging |
| `AttachmentDatabase.swift` | Actor wrapping raw SQLite + FTS5 index for attachment search. Uses `Logger` (not print). |
| `AttachmentIndexer.swift` | Async indexing with CPU throttling |
| `AttachmentSearchService.swift` | Hybrid FTS + semantic embedding search |
| `AvatarCache.swift` | Avatar image caching (uses shared `stableHash` for cache keys). Network fetch extracted to `@concurrent private func fetchAndCache(url:fileURL:)`. |
| `BIMIService.swift` | BIMI logo resolution via DNS-over-HTTPS. `resolveBIMI` is `@concurrent private`. Uses `LRUCache<String, String>(maxSize: 500)`. |
| `CalendarInviteParser.swift` | iCalendar (.ics) parsing for calendar invite cards |
| `BackgroundSyncer.swift` | Actor for bulk GRDB writes (all methods `async throws`, using GRDB async write). Upserts messages/labels/contacts, delta sync, body updates, FTS maintenance. Shared `upsertSingleMessage` helper used by both `upsertMessages` and `applyDelta` (DRY). `updateThreadCounts` helper used in all 3 write paths. FTS always uses `FTSManager.update` (DELETE + INSERT) unconditionally — safe for new and existing messages. `thread_message_count` updated via set-based `UPDATE` (single SQL per batch). Attachments use `upsert` for concurrent writer safety. |
| `ContactModels.swift` | `StoredContact` (`Identifiable`, `Hashable`, `Sendable`), `ContactStore` (legacy cleanup — removes deprecated UserDefaults keys on account removal), `ContactPhotoCache` (in-memory `Mutex`), `GoogleUserInfo` |
| `ContentExtractor.swift` | PDF/OCR/Word/text extraction + embedding generation |
| `CPUMonitor.swift` | Adaptive CPU throttling for background tasks. `recommendedDelay(base:)` takes and returns `Duration`. |
| `EmailClassifier.swift` | Apple Foundation Models classification — categorizes emails by priority, sentiment, category. Persists tags to GRDB. Uses `LRUCache<String, EmailTags>(maxSize: 500)`. `classifyBatch` checks `Task.isCancelled` before each email and reuses a single `LanguageModelSession` across all emails in the batch. |
| `EmailPrintService.swift` | Print formatting via WKWebView |
| `FullSyncEngine.swift` | Actor orchestrating complete offline sync per account: initial full sync (paginated messages.list + batch get, historyId from `getProfile` before listing), incremental History API polling (30-60s adaptive, quota per history page), body pre-fetch (30s backoff on error), label refresh (5 min, ETag-based — skips processing on 304 Not Modified), contact refresh (30 min). State machine: idle → initialSync → monitoring. Init takes explicit `api:` parameter (no `@MainActor` on init). Uses `QuotaTracker` for API pacing. `triggerIncrementalSync` stores its task for cancellation. Incremental sync saves `historyId` only after all message fetches and DB writes succeed. History ID expiry detection checks response body for `"notFound"` (not just HTTP 404 status). Sender parsing in `fireNotifications` uses `GmailDataTransformer.parseContactCore`. Restart on 404 cancels sibling tasks directly (not via `stop()`) to avoid self-cancelling `restartTask`. `updatePollingInterval(appIsActive:windowIsKey:)` sets 60s override when inactive. |
| `QuotaTracker.swift` | Actor pacing Gmail API calls via sliding-window budget (12,000 units/min default, reserving 3,000 for interactive) |
| `LabelSyncService.swift` | Label + category unread count syncing via ETag-cached `listLabels(etag:)` (returns cached data on 304 Not Modified). Singleton (`static let shared`, `private init()`). |
| `LabelSuggestionService.swift` | AI-powered Gmail label suggestions via Foundation Models |
| `NetworkMonitor.swift` | `@MainActor` online/offline detection via NWPathMonitor. `isConnected` is `private(set)`. |
| `NotificationService.swift` | `UNUserNotificationCenter` notifications with reply/archive/mark-read actions. ARCHIVE and MARK_READ handlers run as independent tasks (no cancellation of prior actions) and fall back to `OfflineActionQueue` on API failure. Uses `Logger` (not print). |
| `OfflineActionQueue.swift` | Queues email mutations (archive, trash, star, unstar, spam, markRead, markUnread, addLabel, removeLabel) when offline; drains FIFO on reconnect with stored/cancellable drain task. Backs storage via `PerAccountFileStore<OfflineAction>`. Label operations use `batchModifyLabels`. `persistRemainingIds` saves to disk for crash-resilient progress tracking. `load()` merges disk actions with in-memory (deduplicates by ID). Per-message label actions use `removeAll(where:)` for value-based pruning. `deleteAccount(_:)` clears pending actions and removes the on-disk JSON file. |
| `PeopleAPIService.swift` | Google People API — contact fetching (connections + otherContacts + directory people for Google Workspace) with sync token support for incremental updates, photo cache population. Both `loadContactPhotos(accountID:syncer:)` and `refreshContacts(accountID:syncer:)` take a caller-supplied `BackgroundSyncer` parameter (single-writer pattern). `nonisolated` helper methods (`mergeContacts`, `deduplicateContacts`) use O(n) dictionary lookups off MainActor. Uses `Logger` (not print). Directory sync gated by `syncDirectoryContacts` UserDefault. All three contact sources (connections, otherContacts, directory) use `needsFullFetch` flags to handle 410 sync token expiry → full re-fetch. |
| `QuickReplyService.swift` | AI-powered quick reply suggestions. Uses `LRUCache<String, [String]>(maxSize: 200)`. `generateReplies` returns cached results internally (standalone `cachedReplies` removed — `SmartReplyProvider` serves that role). |
| `ScheduledSendStore.swift` | Persists scheduled-send items per account via `PerAccountFileStore<ScheduledSendItem>` with send-time monitoring. `deleteAccount(_:)` clears in-memory data and removes the on-disk file. |
| `SmartReplyProvider.swift` | Foundation Models smart reply chip generation (contextual reply suggestions). Uses `LRUCache<String, [String]>(maxSize: 200)`. |
| `SnoozeMonitor.swift` | Background timer that un-snoozes emails when their snooze-until date arrives. Errors tracked via per-item failure counts; a toast is shown after `failureNotifyThreshold` (5) consecutive failures, then the item is removed from the store to prevent infinite retry loops. |
| `SnoozeStore.swift` | Persists snoozed email items per account via `PerAccountFileStore<SnoozedItem>`. `deleteAccount(_:)` clears in-memory data and removes the on-disk file. |
| `SignatureResolver.swift` | Signature HTML lookup per alias, HTML signature replacement in compose body |
| `SpotlightIndexer.swift` | CoreSpotlight email indexing for Spotlight search. `indexEmail` is `async` (sequential index + prune, no fire-and-forget races). Prunes at 1000 entries. |
| `SubscriptionsStore.swift` | Detects newsletter/subscription emails, manages unsubscribe state. Uses `analysisGeneration` counter to guard against defer-based corruption during concurrent analysis. `URLValidityCache` capped at 500 entries with 25% partial eviction. |
| `SummaryService.swift` | AI-powered email summaries (delegates to `String.cleanedForAI` for preprocessing) |
| `ThumbnailCache.swift` | Thumbnail generation + LRU caching with concurrency limiting. Disk I/O via `@concurrent static func writeThumbnail`. |
| `ToastManager.swift` | Toast notification state (show/dismiss, typed messages). `currentToast` is `private(set)`. |
| `TrackerBlockerService.swift` | HTML sanitization, tracking pixel/domain blocking (O(1) domain lookup). `styleWidthSmallRegex` and `styleHeightSmallRegex` are pre-compiled `static` properties for spy pixel detection. |
| `UndoActionManager.swift` | Undo toast state machine (schedule -> countdown -> confirm/undo). Countdown tick rate is 250ms. `pendingActions`, `progress`, and `timeRemaining` are `private(set)`. |
| `UnsubscribeService.swift` | Parses List-Unsubscribe headers, RFC 8058 one-click POST |
