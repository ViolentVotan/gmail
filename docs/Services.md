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
OAuth flow, token storage (Keychain), token refresh. `OAuthService` handles the Google OAuth PKCE flow. `TokenStore` persists tokens securely. `AuthToken` is the token value type (`Codable`, `Sendable`) with expiration tracking (60-second pre-refresh buffer).

### `Protocols/`
- `MessageFetching` — Protocol abstracting the Gmail message API surface (`@MainActor`, `Sendable`, typed throws). Methods include `getProfile(accountID:)` for history ID retrieval. `GmailMessageService` conforms. Enables testing via mocks.

### `Gmail/`
Gmail REST API wrappers. One service per domain:
- `GmailAPIClient` — HTTP layer (auth headers, base URL, per-account token refresh coalescing via `refreshAndRetry`/`performRefresh`, retry with exponential backoff + Retry-After on 429/500/503, 401 auto-retry on standard and batch requests, generic `batchFetch<T>()` for batch GET operations with `@concurrent fetchSingleBatch`, `requestURL()` for non-Gmail Google APIs, `Logger`-based diagnostics). `GmailAPIError` includes `dailyLimitExceeded` and `domainPolicy` cases. Batch response parsing strips the `response-` prefix from Content-IDs. `GmailPathBuilder` utility enum provides `queryAllowed` charset (internal), `labelQueryParam`, `sendAsPath`.
- `GmailMessageService` — Messages, threads, mutations (trash, archive, star, labels), History API. Label modifications delegate to a single `modifyLabels` method. `batchModifyLabels(ids:add:remove:accountID:)` applies label changes in batches of 1000 (50 quota units per call). Uses `GmailPathBuilder.queryAllowed` for query parameter encoding.
- `GmailLabelService` — Label CRUD
- `GmailProfileService` — Gmail profile info, user identity (OAuth userinfo), send-as aliases, signature management
- `GmailSendService` — Compose, send, draft CRUD (RFC 2822 MIME encoding with RFC 2047 header encoding). Outgoing messages include a `Date:` header via a cached `rfc2822Formatter` (`nonisolated static`).
- `GmailDraftService` — Draft fetch (single + batch via `batchFetch`), used for quick reply draft loading
- `GmailFilterService` — Gmail filter CRUD (list, create, delete filters)
- `GmailModels` — All API response/request types (`Codable` structs)

### Root-level files
| File | Role |
|------|------|
| `APILogger.swift` | API request/response debug logging |
| `AttachmentDatabase.swift` | Actor wrapping raw SQLite + FTS5 index for attachment search |
| `AttachmentIndexer.swift` | Async indexing with CPU throttling |
| `AttachmentSearchService.swift` | Hybrid FTS + semantic embedding search |
| `AvatarCache.swift` | Avatar image caching (uses shared `stableHash` for cache keys) |
| `BIMIService.swift` | BIMI logo resolution via DNS-over-HTTPS. Cache capped at 500 entries with 25% partial eviction. |
| `CalendarInviteParser.swift` | iCalendar (.ics) parsing for calendar invite cards |
| `BackgroundSyncer.swift` | Actor for bulk GRDB writes (upsert messages/labels/contacts, delta sync, body updates, FTS maintenance). `upsertMessages` uses a batch existence check (single SQL query per chunk). `deleteMessages` updates `thread_message_count` after removal. |
| `ContactModels.swift` | `StoredContact`, `ContactStore` (reads from GRDB), `ContactPhotoCache` (in-memory `Mutex`), `GoogleUserInfo` |
| `ContentExtractor.swift` | PDF/OCR/Word/text extraction + embedding generation |
| `CPUMonitor.swift` | Adaptive CPU throttling for background tasks. `recommendedDelay(base:)` takes and returns `Duration`. |
| `EmailClassifier.swift` | Apple Foundation Models classification — categorizes emails by priority, sentiment, category. Persists tags to GRDB. `tagCache` capped at 500 entries with 25% partial eviction. |
| `EmailPrintService.swift` | Print formatting via WKWebView |
| `FullSyncEngine.swift` | Actor orchestrating complete offline sync per account: initial full sync (paginated messages.list + batch get, historyId from `getProfile` before listing), incremental History API polling (30-60s adaptive, quota per history page), body pre-fetch, label refresh (5 min, `format: "minimal"`), contact refresh (30 min). State machine: idle → initialSync → monitoring. Uses `QuotaTracker` for API pacing. `triggerIncrementalSync` stores its task for cancellation. `restartTask` is tracked and cancelled in `stop()`. `updatePollingInterval(appIsActive:windowIsKey:)` sets 60s override when inactive. |
| `QuotaTracker.swift` | Actor pacing Gmail API calls via sliding-window budget (12,000 units/min default, reserving 3,000 for interactive) |
| `LabelSyncService.swift` | Label + category unread count syncing. Singleton (`static let shared`, `private init()`). |
| `LabelSuggestionService.swift` | AI-powered Gmail label suggestions via Foundation Models |
| `NetworkMonitor.swift` | `@MainActor` online/offline detection via NWPathMonitor |
| `NotificationService.swift` | `UNUserNotificationCenter` push notifications with reply/archive/mark-read actions. ARCHIVE and MARK_READ action handlers fall back to `OfflineActionQueue` on API failure. |
| `OfflineActionQueue.swift` | Queues email mutations (archive, trash, star, unstar, spam, markRead, markUnread) when offline; drains FIFO on reconnect with stored/cancellable drain task. `load()` merges disk actions with in-memory (deduplicates by ID). Per-message label actions use `removeAll(where:)` for value-based pruning. |
| `PeopleAPIService.swift` | Google People API — contact fetching (connections + otherContacts + directory people for Google Workspace) with sync token support for incremental updates, photo cache population. `refreshContacts(accountID:syncer:)` takes a `BackgroundSyncer` parameter (caller-supplied). Directory sync gated by `syncDirectoryContacts` UserDefault. |
| `QuickReplyService.swift` | AI-powered quick reply suggestions with bounded cache |
| `ScheduledSendStore.swift` | Persists scheduled-send items per account (file-based JSON) with send-time monitoring |
| `SmartReplyProvider.swift` | Foundation Models smart reply chip generation (contextual reply suggestions). Cache capped at 200 entries with 25% partial eviction. |
| `SnoozeMonitor.swift` | Background timer that un-snoozes emails when their snooze-until date arrives |
| `SnoozeStore.swift` | Persists snoozed email items per account (file-based JSON) |
| `SignatureResolver.swift` | Signature HTML lookup per alias, HTML signature replacement in compose body |
| `SpotlightIndexer.swift` | CoreSpotlight email indexing for Spotlight search (indexes viewed emails, prunes at 1000) |
| `SubscriptionsStore.swift` | Detects newsletter/subscription emails, manages unsubscribe state. Uses `analysisGeneration` counter to guard against defer-based corruption during concurrent analysis. `URLValidityCache` capped at 500 entries with 25% partial eviction. |
| `SummaryService.swift` | AI-powered email summaries (delegates to `String.cleanedForAI` for preprocessing) |
| `ThumbnailCache.swift` | Thumbnail generation + LRU caching with concurrency limiting. Disk I/O via `@concurrent static func writeThumbnail`. |
| `ToastManager.swift` | Toast notification state (show/dismiss, typed messages) |
| `TrackerBlockerService.swift` | HTML sanitization, tracking pixel/domain blocking (O(1) domain lookup). `styleWidthSmallRegex` and `styleHeightSmallRegex` are pre-compiled `static` properties for spy pixel detection. |
| `UndoActionManager.swift` | Undo toast state machine (schedule -> countdown -> confirm/undo) |
| `UnsubscribeService.swift` | Parses List-Unsubscribe headers, RFC 8058 one-click POST |
