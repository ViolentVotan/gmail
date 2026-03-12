# ViewModels

State management layer between Services and Views. Each ViewModel uses the `@Observable` macro with default `MainActor` isolation.

## Guidelines

- ViewModels own mutable state as plain `var` properties (tracked automatically by `@Observable`). Views use `@State` to own ViewModel instances and `@Bindable` when they need write access to bindings.
- ViewModels do **not** import SwiftUI views. They may import `SwiftUI` for animations.
- One ViewModel per major screen/domain.
- **Cache-first pattern**: load from disk -> show instantly -> refresh from API -> persist.
  - Disk cache: `MailCacheStore` (file-based JSON in `~/Library/Application Support/`)
  - In-memory cache: `messageCache: [String: GmailMessage]` avoids redundant API fetches
- **Optimistic UI**: update state before the API call. Revert on failure.
- ViewModels are **account-aware**: `accountID` is always a parameter or stored property.
- Conversion from API models to UI models happens here (e.g. `GmailMessage` -> `Email`).
- **Exception**: `WebRichTextEditorState` remains as `ObservableObject` because it bridges to `NSViewRepresentable` (WKWebView JS interop).

## Files

| File | Role |
|------|------|
| `AppCoordinator.swift` | Navigation state (folder, selection, compose mode, pending draft selection). Parallelised startup loading via `async let`. |
| `AuthViewModel.swift` | OAuth flow, account switching, sign-in/out state |
| `AttachmentStore.swift` | Attachment vault state, exclusion rules, progress tracking |
| `CommandPaletteViewModel.swift` | Fuzzy-matched command search, recent commands, keyboard navigation state |
| `ComposeViewModel.swift` | Draft management, send, auto-save, inline images, Bcc. Reply orchestration (`sendReplyMessage`, `loadExistingDraft`, `scheduleReplyAutoSave`). Shared file-drop and attachment picker logic. |
| `ComposeModeInitializer.swift` | Initializes compose fields based on mode (reply, forward, new) |
| `EmailActionCoordinator.swift` | Email mutations (archive, delete, star, labels) with bulk-action concurrency via `TaskGroup` |
| `EmailDetailViewModel.swift` | Thread loading with disk cache, attachment download. Business logic: compose mode construction (reply/replyAll/forward), attachment transforms, label suggestion application. |
| `EmailSummaryViewModel.swift` | Apple Foundation Models email summary generation with streaming support |
| `MailboxViewModel.swift` | Email list, pagination, delta sync, stale pruning, cache orchestration. Targeted in-place updates for single-message mutations. |
| `PanelCoordinator.swift` | Side panel state (shortcuts, debug, original message, attachments, browser) |
| `UpdaterViewModel.swift` | Sparkle auto-update state |
