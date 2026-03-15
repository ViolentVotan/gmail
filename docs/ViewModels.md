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
| `AppCoordinator.swift` | Navigation state (folder, selection, compose mode, pending draft selection). Owns `MailDatabase` + `BackgroundSyncer` + `FullSyncEngine` lifecycle. Creates/starts engine on appear, stops/recreates on account switch. Wires `SubscriptionsStore.analyze`, `updatePollingInterval` lifecycle. `handleSelectedEmailChange` cancels previous task. Uses `Logger` (not print). `handleAccountChange` calls `loadContacts`. `handleAccountsChange` stops engine on sign-out. Sets `mailboxViewModel.accountID` eagerly. |
| `AuthViewModel.swift` | OAuth flow, account switching, sign-in/out state |
| `AttachmentStore.swift` | Attachment vault state, exclusion rules, progress tracking |
| `CommandPaletteViewModel.swift` | Fuzzy-matched command search, keyboard navigation state. `filteredCommands` cached as stored property (updated via `updateFilteredCommands()`). |
| `ComposeViewModel.swift` | Draft management, send, auto-save, inline images, Bcc. Reply orchestration (`sendReplyMessage`, `loadExistingDraft`, `scheduleReplyAutoSave`). Shared file-drop and attachment picker logic. |
| `ComposeModeInitializer.swift` | Initializes compose fields based on mode (reply, forward, new) |
| `EmailActionCoordinator.swift` | Email mutations (archive, delete, star, spam, labels) with offline queue support and bulk-action concurrency via `TaskGroup`. All undo closures guard on `accountID`. |
| `EmailDetailViewModel.swift` | Thread loading with DB fast path then API refresh, attachment download. Business logic: compose mode construction (reply/replyAll/forward), attachment transforms, label suggestion application. Tracker sanitization via `@concurrent sanitizeOffMainActor`. Smart reply suggestions (`smartReplySuggestions` property, `loadSmartReplies`). |
| `EmailSummaryViewModel.swift` | Apple Foundation Models email summary generation with streaming support |
| `FiltersViewModel.swift` | Gmail filters state: load, create, delete. Integrates with `GmailFilterService`. Account-aware. |
| `MailStore.swift` | `@Observable @MainActor` local draft store, Gmail draft sync, reply draft persistence (`ReplyDraftInfo`). Uses `Logger` (not print). |
| `MailboxViewModel.swift` | Email list driven entirely by GRDB `ValueObservation` — folder switching starts a DB observation, no API calls. DB-first optimistic mutations (read, star, archive, trash, spam, labels). FTS5 local search. `deletePermanently` deletes the message record (via `BackgroundSyncer` or direct write). Uses `Logger` (not print). |
| `PanelCoordinator.swift` | Side panel state (shortcuts, debug, original message, attachments, browser) |
| `SyncProgressManager.swift` | Sync UI progress state (bubble visibility, debounce/linger timers). `SyncPhase` enum: idle, initialSync(synced, estimated), bodyPrefetch(remaining), syncing, success, error. Account-aware, environment-injected. |
