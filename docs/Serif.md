# Serif — Architecture Overview

macOS Gmail client built with Swift/SwiftUI. 3-column layout (sidebar, email list, email detail).

## Folder Structure

| Folder | Role |
|--------|------|
| `Configuration/` | App-level config (API keys, scopes) |
| `Models/` | Data models and local stores |
| `Services/` | Network, auth, business logic |
| `Theme/` | Appearance management (system/light/dark) |
| `Utilities/` | Pure helper functions (no state, no side effects) |
| `ViewModels/` | State management layer between Services and Views |
| `Views/` | SwiftUI views (UI only) |
| `Resources/` | Assets, fonts, static files |

## Core Principles

1. **Unidirectional data flow**: Services -> ViewModels -> Views. Views never call Services directly.
2. **Cache-first**: Contacts, labels, mails, and threads are loaded from disk cache first, then refreshed from API.
3. **Multi-account**: All persistence is keyed by `accountID`. Never assume a single account.
4. **Optimistic UI**: Mutations (archive, trash, star) update the UI immediately, then call the API.
5. **Semantic colors**: Views use SwiftUI semantic colors (`.primary`, `.secondary`, `.tertiary`) and materials — no custom color definitions.

## Entry Point

`SerifApp.swift` -> routes to `OnboardingView` or `ContentView` based on `@AppStorage("isSignedIn")`.
`ContentView.swift` is the main orchestrator: owns ViewModels, wires callbacks, manages navigation state.

## Key Patterns

- **Delta sync**: `HistorySyncService` uses Gmail History API for incremental folder updates. Falls back to full refresh if historyId expires (404).
- **Stale detection**: `MailboxViewModel` verifies cached messages against Gmail on each fetch, pruning messages that were deleted or moved.
- **Draft lifecycle**: Drafts auto-save with a 2s debounce. Quick replies persist their link (threadID -> gmailDraftID) across sessions via `MailStore.replyDrafts`.
- **Tracker blocking**: `TrackerBlockerService` strips tracking pixels, known tracker domains, and CSS background-image trackers from email HTML.
- **Undo system**: `UndoActionManager` queues destructive actions with a configurable countdown. Actions execute after timeout unless cancelled.
