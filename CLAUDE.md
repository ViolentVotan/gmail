# Serif — Native macOS Gmail Client

Swift 6.2 / SwiftUI / macOS 26+ — a native Gmail client with threading, tracker blocking, multi-account, Apple Intelligence (summaries, classification, smart replies), snooze, schedule-send, offline queue, App Intents, command palette, Gmail filters, and push notifications.

## Fork & Upstream

- **Origin (our fork):** `https://github.com/ViolentVotan/gmail.git`
- **Upstream:** `https://github.com/marshallino16/Serif.git`
- When contributing back upstream, **NEVER include CLAUDE.md** (or any `.claude*` files) in a PR.
- Sync: `git fetch upstream && git merge upstream/master`

## Build & Test

Requires **Xcode 26.3+** (full IDE, not just command-line tools).

| Action | Command |
|--------|---------|
| Build | `xcodebuild -scheme Serif -configuration Debug build` |
| Test | `xcodebuild -scheme Serif -destination 'platform=macOS' test` |
| Release | `./scripts/release.sh` |
| Verify in IDE | Use XcodeBuildMCP to verify compilation |

## Setup

1. Google Cloud project with Gmail API enabled + OAuth 2.0 Desktop credentials
2. Create `Serif/Configuration/GoogleCredentials.swift` (gitignored) with OAuth client ID/secret
3. Open `Serif.xcodeproj` in Xcode, build and run

## Architecture

```
Serif/
├── SerifApp.swift      # App entry point
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
├── Intents/            # App Intents (Shortcuts, Spotlight, Siri)
├── Theme/              # AppearanceManager (system/light/dark)
├── Resources/          # Assets, localization
├── Configuration/      # OAuth credentials (gitignored)
└── Utilities/          # Helpers
```

**Patterns:** MVVM with coordinator navigation (`AppCoordinator`, `EmailActionCoordinator`). Per-account GRDB SQLite database (WAL mode) for email persistence; `BackgroundSyncer` actor writes, `ValueObservation` drives reactive UI. See `.claude/rules/swift.md` for code style and architecture rules.

## LSP Tool Routing

This project has the `swift-lsp` Claude Code plugin enabled alongside Serena (see global CLAUDE.md § Serena for the full routing table). The Claude Code `LSP` tool adds these capabilities Serena lacks:

| Task | Tool | Why |
|------|------|-----|
| **Call hierarchy** (who calls X, what does X call) | `LSP` `incomingCalls`/`outgoingCalls` | Serena has no equivalent |
| **Protocol implementations** (who conforms to X) | `LSP` `goToImplementation` | Direct lookup |
| **Quick type check** on a specific line:col | `LSP` `hover` | Lightweight, no activation needed |

Both share the same `sourcekit-lsp` server and Xcode build index — build in Xcode to refresh.

## Gotchas

- TokenStore encryption key stored alongside ciphertext (known security issue from review)
- Some computed properties re-sort on every render (performance issue — known)
- Multi-account stores (`SnoozeStore`, `ScheduledSendStore`, `OfflineActionQueue`) use per-account file persistence — `load()` merges, not replaces
