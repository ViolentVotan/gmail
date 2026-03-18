# Vik — Architecture Overview

macOS Gmail client built with Swift/SwiftUI. `NavigationSplitView` 3-column layout (sidebar, email list, email detail) with Liquid Glass chrome. Dual-mode: Mail and Calendar, switchable via sidebar segmented control (⌘1/⌘2).

## Folder Structure

| Folder | Role |
|--------|------|
| `Configuration/` | App-level config (API keys, scopes) |
| `Database/` | GRDB SQLite persistence — per-account DatabasePool, record types, migrations, FTS5 |
| `Models/` | Data models and local stores |
| `Services/` | Network, auth, business logic, background sync (Gmail + Calendar) |
| `Services/Calendar/` | Google Calendar API v3 — client, services, sync engine, offline queue |
| `Theme/` | Appearance management (system/light/dark) |
| `Utilities/` | Pure helper functions (no state, no side effects); also `PerAccountFileStore` — a generic stateful per-account JSON persistence base |
| `ViewModels/` | State management layer between Services and Views |
| `Views/` | SwiftUI views (UI only) |
| `Views/Calendar/` | Calendar UI — week/day/agenda grids, event detail/editor, mini-month |
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

`VikApp.swift` -> registers `UserDefaults` defaults (notifications, undo duration, AI labels) in `init()`, then routes to `OnboardingView` or `ContentView` based on `@AppStorage("isSignedIn")`. Also registers the `Settings` scene (Cmd+,) with `SettingsView`.

`ContentView.swift` is the main orchestrator: owns ViewModels, wires callbacks, manages navigation state. Uses `NavigationSplitView` for the three-column layout with `@FocusState` pane cycling (Opt+Tab). Sidebar collapse (`⌘\`) toggles between 220pt expanded and 52pt icon-only mode; the built-in sidebar toggle is suppressed (`.toolbar(removing: .sidebarToggle)`) in favor of a custom toggle. `columnVisibility` is locked to `.all` — collapse is managed via `isSidebarCollapsed` state, not NavigationSplitView's visibility system. Advertises `NSUserActivity` for Handoff when viewing an email.

## Key Patterns

- **Delta sync**: `FullSyncEngine` uses Gmail History API for incremental polling (15-60s adaptive). Falls back to full re-sync if historyId expires (404) by resetting sync state and scheduling a `restartTask`.
- **Offline queue**: `OfflineActionQueue` queues mutations (archive, trash, star, spam, send, etc.) when offline and drains on reconnect. Offline send queues pre-built RFC 2822 messages for deferred delivery.
- **Draft lifecycle**: Drafts auto-save with a 2s debounce. Quick replies persist their link (threadID -> gmailDraftID) across sessions via `MailStore.replyDrafts`.
- **Tracker blocking**: `TrackerBlockerService` strips tracking pixels, known tracker domains, and CSS background-image trackers from email HTML.
- **Undo system**: `UndoActionManager` queues destructive actions with a configurable countdown. Actions execute after timeout unless cancelled.
- **Writing Tools**: WKWebView compose editor enables Apple Intelligence Writing Tools via `writingToolsBehavior = .complete`.
- **Translation**: Email detail offers `.translationPresentation()` for reading; reply bar supports compose-side translation via the formatting toolbar translate button.
- **Schedule-send in reply**: `ReplyBarView` integrates `ScheduleSendButton` for deferred reply delivery alongside the standard send button.
- **Rich text editor**: Custom undo stack, blockquote toggle, highlight color picker, font family picker, Cmd+K link popover, ARIA accessibility (`aria-live` formatting announcements via `editor.js`).
- **Threading headers**: `Email.messageIDHeader`/`referencesHeader` + `GmailSendService.buildReferencesChain` ensure proper RFC 2822 In-Reply-To/References chains in replies.
- **Resumable upload**: `GmailAPIClient.uploadResumable` for large message sends via Gmail's resumable upload protocol.
- **Calendar sync**: `CalendarSyncEngine` (actor) polls Google Calendar API v3 with adaptive intervals (30s calendar-active, 60s mail-active, 300s background, 15s post-edit). Uses per-calendar `syncToken` for incremental event changes and syncToken for calendar list sync; recovers from 410 Gone with full resync. Peer to `FullSyncEngine` (both owned by `AppCoordinator`).
- **Calendar offline queue**: `CalendarOfflineActionQueue` queues calendar mutations (create/update/delete/RSVP) when offline with per-account JSON persistence. Drains on network restoration with etag-based conflict detection. 409 Conflict on updates triggers automatic resolution (re-fetch + retry) with user toast on failure.
- **Email↔Calendar integration**: 4 layers — (1) enhanced RSVP via Calendar API on email invites, (2) contextual "meeting with sender" cards, (3) mini-agenda sidebar widget, (4) smart actions (email attendees, schedule meeting, quick-add via ⌘K).
