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
- `MessageFetching` — Protocol abstracting the Gmail message API surface (`@MainActor`, `Sendable`, typed throws). `GmailMessageService` conforms. Enables testing via mocks.

### `Gmail/`
Gmail REST API wrappers. One service per domain:
- `GmailAPIClient` — HTTP layer (auth headers, base URL, per-account token refresh coalescing, retry with exponential backoff + Retry-After on 429/500/503, 401 auto-retry on standard and batch requests, generic `batchFetch<T>()` for batch GET operations, `requestURL()` for non-Gmail Google APIs)
- `GmailMessageService` — Messages, threads, mutations (trash, archive, star, labels), History API. Label modifications delegate to a single `modifyLabels` method.
- `GmailLabelService` — Label CRUD
- `GmailProfileService` — Gmail profile info, user identity (OAuth userinfo), send-as aliases, signature management
- `GmailSendService` — Compose, send, draft CRUD (RFC 2822 MIME encoding with RFC 2047 header encoding)
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
| `BIMIService.swift` | BIMI logo resolution via DNS-over-HTTPS |
| `CalendarInviteParser.swift` | iCalendar (.ics) parsing for calendar invite cards |
| `BackgroundSyncer.swift` | Actor for bulk API sync → GRDB writes (upsert messages/labels/contacts, delta sync, body pre-fetch, FTS maintenance) |
| `ContactModels.swift` | `StoredContact`, `ContactStore` (reads from GRDB), `ContactPhotoCache` (in-memory NSLock), `GoogleUserInfo` |
| `ContentExtractor.swift` | PDF/OCR/Word/text extraction + embedding generation |
| `CPUMonitor.swift` | Adaptive CPU throttling for background tasks |
| `EmailClassifier.swift` | Apple Foundation Models classification — categorizes emails by priority, sentiment, category. Persists tags to GRDB. |
| `EmailPrintService.swift` | Print formatting via WKWebView |
| `HistorySyncService.swift` | Delta sync via Gmail History API with label-aware filtering |
| `LabelSyncService.swift` | Label + category unread count syncing |
| `MessageFetchService.swift` | API pagination, in-memory cache, generation tracking for stale detection |
| `LabelSuggestionService.swift` | AI-powered Gmail label suggestions via Foundation Models |
| `NetworkMonitor.swift` | `@MainActor` online/offline detection via NWPathMonitor |
| `NotificationService.swift` | `UNUserNotificationCenter` push notifications with reply/archive/mark-read actions |
| `OfflineActionQueue.swift` | Queues email mutations (archive, trash) when offline; drains FIFO on reconnect |
| `PeopleAPIService.swift` | Google People API — contact fetching (connections + otherContacts) with sync token support for incremental updates, photo cache population |
| `QuickReplyService.swift` | AI-powered quick reply suggestions with bounded cache |
| `ScheduledSendStore.swift` | Persists scheduled-send items per account (file-based JSON) with send-time monitoring |
| `SmartReplyProvider.swift` | Foundation Models smart reply chip generation (contextual reply suggestions) |
| `SnoozeMonitor.swift` | Background timer that un-snoozes emails when their snooze-until date arrives |
| `SnoozeStore.swift` | Persists snoozed email items per account (file-based JSON) |
| `SignatureResolver.swift` | Signature HTML lookup per alias, HTML signature replacement in compose body |
| `SpotlightIndexer.swift` | CoreSpotlight email indexing for Spotlight search (indexes viewed emails, prunes at 1000) |
| `SubscriptionsStore.swift` | Detects newsletter/subscription emails, manages unsubscribe state |
| `SummaryService.swift` | AI-powered email summaries (delegates to `String.cleanedForAI` for preprocessing) |
| `ThumbnailCache.swift` | Thumbnail generation + LRU caching with concurrency limiting |
| `ToastManager.swift` | Toast notification state (show/dismiss, typed messages) |
| `TrackerBlockerService.swift` | HTML sanitization, tracking pixel/domain blocking (O(1) domain lookup) |
| `UndoActionManager.swift` | Undo toast state machine (schedule -> countdown -> confirm/undo) |
| `UnsubscribeService.swift` | Parses List-Unsubscribe headers, RFC 8058 one-click POST |
