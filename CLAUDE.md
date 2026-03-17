# Vik — Native macOS Gmail Client

Swift 6.2 / SwiftUI / macOS 26+ — a native Gmail client with threading, tracker blocking, multi-account, Apple Intelligence (summaries, classification, smart replies, translation, notification priority, onscreen awareness, tool calling), snooze, schedule-send, offline queue, App Intents (AssistantSchemas mail domain), command palette, Gmail filters, and local notifications.

## Fork & Upstream

- **Origin (our fork):** `https://github.com/ViolentVotan/gmail.git`
- **Upstream:** `https://github.com/marshallino16/Serif.git`
- When contributing back upstream, **NEVER include CLAUDE.md** (or any `.claude*` files) in a PR.
- Sync: `git fetch upstream && git merge upstream/master`

## Build & Test

Requires **Xcode 26.3+** (full IDE, not just command-line tools).

| Action | Command |
|--------|---------|
| Build | `xcodebuild -scheme Vik -configuration Debug build` |
| Test | `xcodebuild -scheme Vik -destination 'platform=macOS' test` |
| Release | `./scripts/release.sh` |

<!-- Human-only setup reference (hidden from Claude context):
1. Google Cloud project with Gmail API enabled + OAuth 2.0 Desktop credentials
2. Create Vik/Configuration/GoogleCredentials.swift (gitignored) with OAuth client ID/secret
3. Open Vik.xcodeproj in Xcode, build and run -->

## Architecture

```
Vik/
├── VikApp.swift      # App entry point
├── ContentView.swift   # Root view
├── Views/              # SwiftUI views
├── ViewModels/         # MVVM view models (one per feature)
├── Models/             # Data models
├── Database/           # GRDB SQLite persistence (per-account)
│   ├── Records/        # GRDB record types (MessageRecord, LabelRecord, etc.)
│   ├── MailDatabase.swift          # DatabasePool owner, WAL config, integrity
│   ├── MailDatabaseMigrations.swift # Schema migrations
│   ├── MailDatabaseQueries.swift   # Centralized read queries
│   ├── FTSManager.swift            # FTS5 full-text search maintenance
│   └── CacheMigration.swift        # One-time JSON→GRDB migration
├── Services/           # Business logic & API
│   ├── Auth/           # OAuth & token management
│   ├── Gmail/          # Gmail REST API clients (one per domain)
│   └── BackgroundSyncer.swift      # Actor for bulk API sync → DB writes
├── Intents/            # App Intents with AssistantSchemas mail domain (Shortcuts, Spotlight, Siri)
├── Theme/              # AppearanceManager, DesignTokens (spacing, corner radius, brand colors, haptics, shared modifiers)
├── Resources/          # Assets, localization
├── Configuration/      # OAuth credentials (gitignored)
└── Utilities/          # Helpers
```

**Patterns:** MVVM with coordinator navigation (`AppCoordinator`, `EmailActionCoordinator`). Per-account GRDB SQLite database (WAL mode) for email persistence; `BackgroundSyncer` actor writes, `ValueObservation` drives reactive UI. `SyncProgressManager` (@Observable, environment-injected) drives an always-visible interactive liquid glass bubble at the sidebar bottom — tappable to trigger manual sync, with linger timers for success/error states, reset on account switch.

**Path-scoped rules** (`.claude/rules/`): `_code-style.md` (Swift conventions, auto-synced from Serena `code_style` memory), `database.md` (Database layer), `testing.md` (tests), `safety.md` (CI/config safety).

## LSP Tool Routing

This project has the `swift-lsp` Claude Code plugin enabled alongside Serena (see global CLAUDE.md § Serena for the full routing table). The Claude Code `LSP` tool adds these capabilities Serena lacks:

| Task | Tool | Why |
|------|------|-----|
| **Call hierarchy** (who calls X, what does X call) | `LSP` `incomingCalls`/`outgoingCalls` | Serena has no equivalent |
| **Protocol implementations** (who conforms to X) | `LSP` `goToImplementation` | Direct lookup |
| **Quick type check** on a specific line:col | `LSP` `hover` | Lightweight, no activation needed |

Both share the same `sourcekit-lsp` server and Xcode build index — build in Xcode to refresh.

## Design Decisions

- **Polling over push:** We use polling-based sync (60s foreground / 300s background) intentionally. No Gmail `users.watch` / Cloud Pub/Sub push notifications — the complexity of server-side Pub/Sub infrastructure isn't worth it for a native desktop client. Don't suggest or implement push notifications.

## Gotchas

- Some computed properties re-sort on every render (performance issue — known)
- Multi-account stores (`SnoozeStore`, `ScheduledSendStore`, `OfflineActionQueue`) use per-account file persistence — `load()` merges, not replaces
