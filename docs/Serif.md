# Serif — Architecture Overview

macOS Gmail client built with Swift/SwiftUI. `NavigationSplitView` 3-column layout (sidebar, email list, email detail) with Liquid Glass chrome.

## Folder Structure

| Folder | Role |
|--------|------|
| `Configuration/` | App-level config (API keys, scopes) |
| `Database/` | GRDB SQLite persistence — per-account DatabasePool, record types, migrations, FTS5 |
| `Models/` | Data models and local stores |
| `Services/` | Network, auth, business logic, background sync |
| `Theme/` | Appearance management (system/light/dark) |
| `Utilities/` | Pure helper functions (no state, no side effects) |
| `ViewModels/` | State management layer between Services and Views |
| `Views/` | SwiftUI views (UI only) |
| `Resources/` | Assets, fonts, static files |

## Core Principles

1. **Unidirectional data flow**: Services -> ViewModels -> Views. Views never call Services directly.
2. **DB-first**: Emails, labels, and threads are loaded from the local GRDB database first (instant), then refreshed from API. `BackgroundSyncer` writes API responses to DB; `ValueObservation` reactively updates the UI.
3. **Multi-account**: All persistence is keyed by `accountID`. Never assume a single account.
4. **Optimistic UI**: Mutations (archive, trash, star) update the UI immediately, then call the API.
5. **Semantic colors**: Views use SwiftUI semantic colors (`.primary`, `.secondary`, `.tertiary`) and materials — no custom color definitions.
6. **Semantic typography**: All fonts use semantic text styles (`.body`, `.caption`, `.title2`, etc.) for Dynamic Type support. No hardcoded `.system(size:)` except proportional avatar sizing.
7. **Accessibility**: Email rows, toasts, avatars, and badges have VoiceOver labels, hints, and traits.

## Entry Point

`SerifApp.swift` -> registers `UserDefaults` defaults (notifications, undo duration, AI labels) in `init()`, then routes to `OnboardingView` or `ContentView` based on `@AppStorage("isSignedIn")`. Also registers the `Settings` scene (Cmd+,) with `SettingsView`.

`ContentView.swift` is the main orchestrator: owns ViewModels, wires callbacks, manages navigation state. Uses `NavigationSplitView` for the three-column layout with `@FocusState` pane cycling (Opt+Tab). Advertises `NSUserActivity` for Handoff when viewing an email.

## Key Patterns

- **Delta sync**: `FullSyncEngine` uses Gmail History API for incremental polling (15-60s adaptive). Falls back to full re-sync if historyId expires (404) via `needsFullResync` flag.
- **Offline queue**: `OfflineActionQueue` queues mutations (archive, trash, star, spam, etc.) when offline and drains on reconnect.
- **Draft lifecycle**: Drafts auto-save with a 2s debounce. Quick replies persist their link (threadID -> gmailDraftID) across sessions via `MailStore.replyDrafts`.
- **Tracker blocking**: `TrackerBlockerService` strips tracking pixels, known tracker domains, and CSS background-image trackers from email HTML.
- **Undo system**: `UndoActionManager` queues destructive actions with a configurable countdown. Actions execute after timeout unless cancelled.
