# ViewModels

State management layer between Services and Views. Each ViewModel uses the `@Observable` macro with default `MainActor` isolation.

## Guidelines

- ViewModels own mutable state as plain `var` properties (tracked automatically by `@Observable`). Views use `@State` to own ViewModel instances and `@Bindable` when they need write access to bindings.
- ViewModels do **not** import SwiftUI views. They may import `SwiftUI` for animations.
- One ViewModel per major screen/domain.
- **DB-first pattern**: `FullSyncEngine` syncs all messages to GRDB → `ValueObservation` drives the UI → folder switching is instant (zero API calls).
  - Database: per-account GRDB SQLite (`~/Library/Application Support/com.vikingz.serif.app/mail-db/`)
- **Optimistic mutations**: write to DB first → ValueObservation updates UI → API call → revert on failure via `restoreLabelsInDatabase`.
- ViewModels are **account-aware**: `accountID` is always a parameter or stored property.
- Conversion from API models to UI models happens here (e.g. `GmailMessage` -> `Email`).
- **Exception**: `WebRichTextEditorState` remains as `ObservableObject` because it bridges to `NSViewRepresentable` (WKWebView JS interop).

## Files

| File | Role |
|------|------|
| `AppCoordinator.swift` | Navigation state (folder, selection, compose mode, pending draft selection). Owns `MailDatabase` + `BackgroundSyncer` + `FullSyncEngine` lifecycle. Creates/starts engine on appear, stops/recreates on account switch (engine reference captured in local variable before nilling to ensure `stop()` runs). `isAccountSwitching` guard prevents cascading `onChange` from cancelling account setup. Wires `SubscriptionsStore.analyze`, `updatePollingInterval` lifecycle. `handleSelectedEmailChange` cancels previous task. Uses `Logger` (not print). `handleAccountChange` captures `oldID` before mutation, calls `loadContacts` (async via `Task` to avoid blocking MainActor), delegates to private `setupAccount` helper, cancels `navigationTask`. `handleAccountsChange` stops engine on sign-out and clears `SummaryService.accountID`. Sets `mailboxViewModel.accountID` eagerly. `displayedEmails` is a stored `private(set) var` updated via `updateDisplayedEmails()` at all trigger points; `MailboxViewModel.onEmailsChanged` callback (wired in init) handles reactive DB/search updates. `navigateToMessage` stores a cancellable task with account guard after `await`. `handleQuickReply` and `downloadAttachment` route service calls from ContentView. |
| `AuthViewModel.swift` | OAuth flow, account switching, sign-in/out state. Sign-out revokes OAuth token with Google (best-effort) and delegates all per-account cleanup to `AccountStore.remove`. Resets `isSignedIn` to `false` when the last account is removed, returning the user to `OnboardingView`. |
| `AttachmentStore.swift` | Attachment vault state, exclusion rules, progress tracking |
| `CommandPaletteViewModel.swift` | Fuzzy-matched command search, keyboard navigation state. `filteredCommands` cached as stored property (updated via `updateFilteredCommands()`). |
| `ComposeViewModel.swift` | Draft management, send, auto-save, inline images, Bcc. Reply orchestration (`sendReplyMessage`, `loadExistingDraft`, `scheduleReplyAutoSave`). `openAttachmentPicker() async -> [URL]` uses NSOpenPanel async API. Shared file-drop logic. |
| `ComposeModeInitializer.swift` | Initializes compose fields based on mode (reply, forward, new) |
| `EmailActionCoordinator.swift` | Email mutations (archive, delete, star, spam, labels) with offline queue support. Shared mutation path via private `performUndoableAction` helper. Bulk methods use protocol-injected `MessageFetching.batchModifyLabels` (default: `GmailMessageService.shared`) instead of per-message `TaskGroup` calls. `bulkMarkUnread` has optimistic DB updates; `bulkMarkUnread`/`bulkMarkRead` show toast on API failure. All undo closures use `[weak vm]` captures and guard on `accountID` to prevent retain cycles during account switch. |
| `EmailDetailViewModel.swift` | Thread loading with DB fast path (fires `onMessagesRead` for unread badge sync) then API refresh (skips duplicate tracker analysis when data unchanged), attachment download. `backgroundTasks` is `Mutex<[Task]>` for safe `deinit` cancellation. Business logic: compose mode construction (reply/replyAll/forward), attachment transforms, label suggestion application. Tracker sanitization via `@concurrent sanitizeOffMainActor`. Smart reply suggestions (`smartReplySuggestions` property, `loadSmartReplies`). |
| `EmailSummaryViewModel.swift` | Apple Foundation Models email summary generation with streaming support. `startStreaming` cancels any in-flight `streamTask`/`insightTask` before starting new ones. |
| `FiltersViewModel.swift` | Gmail filters state: load, create, delete. `deleteFilter` shows toast on failure. Integrates with `GmailFilterService`. Account-aware. |
| `MailStore.swift` | `@Observable @MainActor` local draft store, Gmail draft sync, reply draft persistence (`ReplyDraftInfo`). Drafts folder result (`emails(for: .drafts)`) cached via `_cachedDrafts`, invalidated by `didSet` on `emails` and `gmailDrafts`. Uses `Logger` (not print). |
| `MailboxViewModel.swift` | Email list driven entirely by GRDB `ValueObservation` (`trackingConstantRegion` + async `for try await values` API for guaranteed MainActor delivery via `observationTask`) — folder switching starts a DB observation, no API calls. `onEmailsChanged` callback (`@ObservationIgnored`) fires on `emails` `didSet` for reactive updates. DB-first optimistic mutations (read, star, archive, trash, spam, labels) with `ToastManager` error feedback on all failure paths. `addLabel`/`removeLabel` support offline via `OfflineActionQueue`. `applyReadLocally` batches all updates in a single `dbPool.write` transaction. All 5 label mutation methods refactored into a shared `writeLabels(_:ensureLabelRecords:transform:)` helper that syncs `is_read`/`is_starred` denormalized columns. `loadCategoryUnreadCounts` uses parameterized SQL (no string interpolation). `enrichmentTask` cancelled on account switch. `threadedEmails` uses `max(by:)` instead of `sorted.first`. FTS5 local search. `deletePermanently` deletes the message record (via `BackgroundSyncer` or direct write). Uses `Logger` (not print). |
| `PanelCoordinator.swift` | Side panel state (shortcuts, debug, original message, attachments, browser). Uses `SerifAnimation.springDefault`/`.springSnappy` instead of inline spring values. |
| `SyncProgressManager.swift` | Sync UI progress state (bubble visibility, debounce/linger timers). `SyncPhase` enum: idle, initialSync(synced, estimated), bodyPrefetch(remaining), syncing, success, error. Account-aware, environment-injected. |
