# Services

Business logic, networking, and side effects. This is the **only** layer that talks to external APIs.

## Guidelines

- Services are **singletons** (`static let shared`) — stateless request handlers, not state containers.
- All API calls go through `GmailAPIClient` which handles auth tokens, rate limiting, and logging.
- Services return raw API models (`GmailMessage`, `GmailLabel`, etc.). They do NOT return UI models.
- Error handling: throw errors up to the ViewModel. Services don't show UI or set `@Published` state.
- Services must be **account-aware**: every method takes `accountID` as parameter.
- No SwiftUI imports. No `@Published`, no `ObservableObject` (except `UndoActionManager` which is a UI singleton by design).

## Subfolders

### `Auth/`
OAuth flow, token storage (Keychain), token refresh. `OAuthService` handles the Google OAuth PKCE flow. `TokenStore` persists tokens securely.

### `Gmail/`
Gmail REST API wrappers. One service per domain:
- `GmailAPIClient` — HTTP layer (auth headers, base URL, logging)
- `GmailMessageService` — Messages, threads, mutations (trash, archive, star, labels), History API
- `GmailLabelService` — Label CRUD
- `GmailProfileService` — Profile info, contacts, send-as aliases, photos
- `GmailSendService` — Compose, send, draft CRUD (RFC 2822 MIME encoding with RFC 2047 header encoding)
- `GmailDraftService` — Draft fetch (single + batch), used for quick reply draft loading
- `GmailModels` — All API response/request types (`Codable` structs)

### Root-level files
| File | Role |
|------|------|
| `HistorySyncService.swift` | Delta sync via Gmail History API with label-aware filtering |
| `UndoActionManager.swift` | Undo toast state machine (schedule -> countdown -> confirm/undo) |
| `UnsubscribeService.swift` | Parses List-Unsubscribe headers, RFC 8058 one-click POST |
| `SubscriptionsStore.swift` | Detects newsletter/subscription emails, manages unsubscribe state |
| `EmailPrintService.swift` | Print formatting via WKWebView |
| `TrackerBlockerService.swift` | HTML sanitization, tracking pixel/domain blocking |
| `BIMIService.swift` | BIMI logo resolution via DNS-over-HTTPS |
| `NetworkMonitor.swift` | Online/offline detection |
| `AttachmentDatabase.swift` | SQLite FTS5 index for attachment search |
| `AttachmentIndexer.swift` | Async indexing with CPU throttling |
| `AttachmentSearchService.swift` | Hybrid FTS + semantic embedding search |
| `ContentExtractor.swift` | PDF/OCR/Word/text extraction + embedding generation |
| `ThumbnailCache.swift` | Thumbnail generation + LRU caching |
| `AvatarCache.swift` | Avatar image caching |
| `CPUMonitor.swift` | Adaptive CPU throttling for background tasks |
