# Codebase Review — Serif macOS Gmail Client

**Date**: 2026-03-11
**Scope**: Full codebase (121 Swift files)
**Threshold**: ≥80% confidence only

## Summary

| Category | Critical | Important | Minor | Total |
|----------|----------|-----------|-------|-------|
| Security | 1 | 1 | 3 | 5 |
| Quality | 4 | 5 | 2 | 11 |
| Efficiency | 3 | 7 | 1 | 11 |
| Integration | 1 | 2 | 0 | 3 |
| DRY | 1 | 5 | 1 | 7 |
| **Total** | **10** | **20** | **7** | **37** |

After deduplication: **~30 unique findings**. Several were flagged by multiple agents.

---

## Fixes Applied (12 files, 129 insertions, 74 deletions)

- [x] **Force unwrap on `thread!`** — `EmailDetailViewModel.swift:250` → safe unwrap via `guard let current = thread`
- [x] **`parseContacts` correctness bug** — `MailStore.swift:168` → replaced broken local lambda with `GmailDataTransformer.parseContacts()` (contacts with display names were being set as both name AND email)
- [x] **`replyDrafts` not keyed by accountID** — `MailStore.swift` → persistence key now includes accountID, loaded on account switch
- [x] **No-op Mute/Block buttons** — `DetailToolbarView.swift:123-124` → commented out with TODO until implemented
- [x] **`objectWillChange.send()` redundant** — `MailboxViewModel.swift:412` → removed (labels is @Published, already triggers)
- [x] **Missing `final` on coordinators** — `AppCoordinator.swift`, `EmailActionCoordinator.swift` → added `final`
- [x] **`animateChips` off-by-one** — `ReplyBarView.swift:339` → changed `0...count` to `0..<count` with empty guard
- [x] **TrackerBlockerService regex recompilation** — cached all regexes as `static let` + `NSCache` for parameterized patterns
- [x] **AvatarCache no in-memory layer** — added `NSCache<NSString, NSImage>` (200 limit) + negative cache; disk reads only on miss
- [x] **CPUMonitor data race** — rewrote with `OSAllocatedUnfairLock` protecting all mutable state; now `Sendable`
- [x] **Attachment download error swallowed** — `EmailDetailView.swift:335` → added `ToastManager.show()` error feedback
- [x] **2s polling timer redundant** — `SettingsCardsView.swift:63` → removed timer (button callback already updates count)

---

## Deferred (needs architecture discussion or broader refactor)

### Security — Critical
- ~~**TokenStore: encryption key stored alongside ciphertext**~~ — **RESOLVED.** Encryption key now stored in macOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

### Security — High
- **WKWebView navigation policy too permissive** — `decidePolicyFor` allows all non-`linkActivated` navigations. Malicious email HTML could trigger programmatic navigation to `file://` or `javascript:` URIs. Fix: default to `.cancel`, allow only the initial `loadHTMLString` load. Also set `javaScriptEnabled = false` for the email reader.

### Performance — High
- ~~**`emails` computed property re-sorts on every render**~~ — **RESOLVED.** `emails` was already a stored `private(set) var`. Coalesced `applyHistorySync` mutations with `suppressRecompute` to avoid 3-4 redundant recomputes per sync cycle.
- ~~**MailCacheStore blocking main thread**~~ — **NOT AN ISSUE.** No `MailCacheStore` class exists in codebase — review artifact.
- ~~**N+1 stale message verification**~~ — **ALREADY FIXED.** `verifyMessages()` in `MessageFetchService` already uses `getMessages(ids:)` batch API.

### Architecture
- ~~**Views calling Services directly**~~ — **PARTIALLY RESOLVED.** `SignaturesSettingsView` extracted to injected callback. Remaining views (AvatarView, UnifiedToastLayer, AttachmentCardView) access `@Observable` caches/monitors for pure presentation — adding ViewModel indirection would be over-engineering.
- **EmailDetailVM mark-as-read bypasses MailboxVM** — Unread counts drift until next refresh. Fix: route through MailboxVM callback.
- **`mailStore ?? MailStore()` ephemeral fallback** — `EmailDetailView.swift:272` creates disconnected instance, draft saves are lost. Fix: make `mailStore` non-optional.

### DRY
- ~~**`resolveInlineImages` duplicated**~~ — **NOT DUPLICATED.** Both methods delegate to shared `replaceCIDReferences()` helper; they differ intentionally (latest uses tracker-sanitized HTML, older use raw HTML).
- ~~**File-size formatting**~~ — **RESOLVED.** Unified on `ByteCountFormatter.string(fromByteCount:countStyle:)` via `GmailDataTransformer.sizeString`.
- ~~**Date formatting**~~ — **RESOLVED.** Centralized to cached formatters in `DateFormatting.swift` (`formattedTime`, `formattedDayTime`, `formattedGmailQuery`).

### Efficiency
- ~~**`allEmbeddings` unbounded load**~~ — **ALREADY CAPPED.** `allEmbeddings(accountID:limit:)` has `limit: Int = 1000` default.
- ~~**Sequential older message inline image resolution**~~ — **ALREADY PARALLEL.** `resolveInlineImagesForOlderMessages()` uses `withTaskGroup`.
- ~~**`markAsRead` sequential per thread message**~~ — **ALREADY CONCURRENT.** `EmailDetailViewModel.loadThread` uses `withTaskGroup` for marking unread messages.

### Code Quality (resolved 2026-03-14)
- ~~**Empty catch block in WebRichTextEditorCoordinator**~~ — Added os.Logger warning for failed image writes.
- ~~**Unguarded `print()` in production**~~ — Replaced with os.Logger across HistorySyncService, OfflineActionQueue, AttachmentIndexer, MailboxViewModel, WebRichTextEditorCoordinator.
- ~~**`assertionFailure` setter traps**~~ — SnoozeStore and ScheduledSendStore `items` are now read-only computed properties.
- ~~**MailStore in Models/**~~ — Moved to ViewModels/ (architecturally a ViewModel).
