# Vik — Native macOS Gmail Client

Swift 6.2 / SwiftUI / macOS 26+ — a premium, native Gmail client with threading, tracker blocking, multi-account, Apple Intelligence (summaries, classification, translation, notification priority, onscreen awareness, tool calling), snooze, schedule-send, offline queue, App Intents (AssistantSchemas mail domain), command palette, Gmail filters, local notifications, and **full Google Calendar integration** (month/week/day/agenda views, deep email↔calendar integration, offline queue with etag conflict resolution).

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
| Local install | `./scripts/install-local.sh` |
| GitHub release | `./scripts/release.sh <version>` |

**`install-local.sh`** — builds Release with Xcode automatic signing (Andre Meyer Personal Team / `9GSLSZ92Z7`), verifies the code signature has a valid team identifier (rejects ad-hoc), and installs to `/Applications`. Use for local deployment on this machine.

**`release.sh`** — pushes a git tag (`v<version>`), which triggers the GitHub Actions workflow (`.github/workflows/release.yml`) to build with Developer ID signing, notarize, create a DMG, and publish a GitHub Release. Requires CI secrets for certificates and Apple ID credentials.

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
│   └── CacheMigration.swift        # One-time JSON→GRDB migration
├── Services/           # Business logic & API
│   ├── Auth/           # OAuth & token management
│   ├── Gmail/          # Gmail REST API clients (one per domain)
│   ├── Calendar/       # Google Calendar API v3 — client, services, sync engine, offline queue
│   ├── Protocols/      # Service protocol abstractions
│   ├── CalendarIntegrationService.swift  # Cross-feature email↔calendar coordination
│   └── BackgroundSyncer.swift      # Actor for bulk API sync → DB writes
├── Intents/            # App Intents with AssistantSchemas mail domain (Shortcuts, Spotlight, Siri)
├── Theme/              # AppearanceManager, DesignTokens (spacing, corner radius, brand colors, haptics, shared modifiers)
├── Resources/          # Assets, localization
├── Configuration/      # OAuth credentials (gitignored)
└── Utilities/          # Helpers
```

**Patterns:** MVVM with coordinators (`AppCoordinator`, `EmailActionCoordinator`). `AppCoordinator` is a thin orchestrator owning 7 domain sub-coordinators: `NavigationCoordinator` (folder/account/label/category selection), `SelectionCoordinator` (email selection + displayedEmails cache), `ComposeCoordinator` (compose mode + signatures), `CalendarCoordinator` (viewMode + CalendarViewModel + CalendarSyncEngine), `DialogCoordinator` (confirmation dialogs), `SyncCoordinator` (mailDatabase + syncEngine + backgroundSyncer + contacts + caches), `PanelCoordinator` (help panel, email detail panel visibility). Views access sub-coordinators directly (e.g., `coordinator.selection.selectedEmail`). Cross-domain operations go through AppCoordinator orchestration methods. Dual-mode app: Mail (⌘1) and Calendar (⌘2), switchable via sidebar segmented control. `CalendarBackgroundSyncer` actor handles calendar DB writes (peer to email's `BackgroundSyncer`). `SyncProgressManager` (@Observable, environment-injected) drives an always-visible interactive liquid glass bubble at the sidebar bottom — tappable to trigger manual sync, with linger timers for success/error states, reset on account switch.

**Path-scoped rules** (`.claude/rules/`): `_code-style.md` (Swift conventions, auto-synced from Serena `code_style` memory), `database.md` (Database layer), `design.md` (UI design), `testing.md` (tests), `safety.md` (CI/config safety).

**Project agent** (`.claude/agents/`): `swift-builder` — background Haiku agent for build/test verification. Dispatch after code changes to confirm compilation and test results without blocking your main context.

## LSP Tool Routing

The Claude Code `LSP` tool (via the `swift-lsp` plugin) supplements Serena with capabilities it lacks:

| Task | Tool | Why |
|------|------|-----|
| **Call hierarchy** (who calls X, what does X call) | `LSP` `incomingCalls`/`outgoingCalls` | Serena has no equivalent |
| **Protocol implementations** (who conforms to X) | `LSP` `goToImplementation` | Direct lookup |
| **Quick type check** on a specific line:col | `LSP` `hover` | Lightweight, no activation needed |

Both share the same `sourcekit-lsp` server and Xcode build index — build in Xcode to refresh.

## Swift/SwiftUI Skill Routing

All skills target **macOS 26+ / Swift 6.2+ exclusively** — no legacy patterns. **Invoke the matching skill before writing code in that area.**

| When working on… | Invoke skill | Why |
|-------------------|-------------|-----|
| `@Observable` VMs, `@State`/`@Bindable`, view composition, `.sensoryFeedback` | `swiftui-patterns` | MV architecture, ownership rules, macOS 26 APIs |
| Actors, `@concurrent`, `@MainActor`, `isolated deinit`, `Sendable`, `TaskGroup`, `Mutex` | `swift-concurrency` | Swift 6.2 approachable concurrency (SE-0466) |
| Tests (`@Test`, `#expect`, `@Suite`, `.serialized`, exit tests, image attachments) | `swift-testing` | Swift Testing framework (Xcode 26) |
| Liquid glass, `glassEffect`, `GlassEffectContainer`, `glassBackgroundEffect` | `swiftui-liquid-glass` | macOS 26 glass API |
| Stacks, grids, `Table`, `ScrollPosition`, forms, `DragContainer`, `.searchable` | `swiftui-layout-components` | Layout + multi-column data views |
| `NavigationStack`, `NavigationSplitView`, sheets, tab bar, deep links | `swiftui-navigation` | Navigation + Liquid Glass sheet morphing |
| `withAnimation`, springs, keyframes, SF Symbols 7 Draw, `@Animatable`, transitions | `swiftui-animation` | Animation API (macOS-native, AppKit bridge) |
| Enums, protocols, generics, `~Copyable`, `borrowing`/`consuming`, parameter packs, `Codable` | `swift-language` | Modern Swift 6.2 idioms |
| Slow rendering, excessive updates, Instruments 26, Cause & Effect graph | `swiftui-performance` | Performance audit (macOS-specific) |
| `NSViewRepresentable`, `NSHostingView`, `NSHostingController`, AppKit bridging | `swiftui-uikit-interop` | AppKit/UIKit interop (macOS primary) |
| Tap/drag/magnify gestures, `NSGestureRecognizerRepresentable`, composition | `swiftui-gestures` | Gesture handling (macOS 26) |
| Bar/line/area/pie charts, `Chart3D`, `SurfacePlot`, data visualization | `swift-charts` | Swift Charts + 3D (macOS 26) |

**Not used:** `swift-data` (project uses GRDB, not SwiftData).

## Codebase Audit

For full codebase audits, reviews, health checks, or multi-dimensional code quality sweeps, **invoke the `audit` skill** (`/audit`). It dispatches 5 parallel Opus agents across concurrency, SwiftUI, architecture/wiring, database, and security — then fixes all CRITICAL/HIGH/MEDIUM issues and verifies the build.

## Design Decisions

- **Hybrid sync — Pub/Sub + polling fallback:** Primary: Google Cloud Pub/Sub (`PubSubService` pull loop + `GmailWatchService` registration). Fallback: polling (60s foreground / 300s background) when Pub/Sub is unavailable (e.g. token lacks `pubsub` scope). `startPubSub()` checks `AuthToken.hasScope()` before starting — tokens issued before the scope was added silently skip Pub/Sub until the user reauthorizes. GCP project: `gws-cli-votan`, subscription: `gmail-notifications-sub`.

## Gotchas

- Multi-account stores (`SnoozeStore`, `ScheduledSendStore`, `OfflineActionQueue`) use per-account file persistence — `load()` merges, not replaces
