# Codebase Structure — Vik

## Layout
```
Vik/                      # Main app
├── VikApp.swift           # Entry point → OnboardingView or ContentView
├── ContentView.swift        # Main orchestrator (owns ViewModels, wires callbacks)
├── Configuration/           # API keys, OAuth scopes (GoogleCredentials.swift is gitignored)
├── Database/                # GRDB SQLite persistence (per-account)
│   ├── Records/             # GRDB record types (MessageRecord, LabelRecord, etc.)
│   ├── MailDatabase.swift
│   ├── MailDatabaseMigrations.swift
│   ├── MailDatabaseQueries.swift
│   ├── FTSManager.swift
│   └── CacheMigration.swift
├── Models/                  # Data models (Email, GmailAccount, ComposeMode, OfflineAction, etc.)
├── Services/                # Business logic & API
│   ├── Auth/                # OAuth & token management
│   ├── Gmail/               # Gmail REST API clients
│   ├── Calendar/            # Google Calendar API v3 — client, services, sync engine, offline queue
│   └── Protocols/           # Service protocols (MessageFetching)
├── ViewModels/              # @Observable state management
│   ├── AppCoordinator       # App-level state coordination (mail + calendar modes)
│   ├── MailboxViewModel     # Email list for account+folder
│   ├── CalendarViewModel    # Calendar UI state + CRUD + reactive DB observation (default: month view)

│   ├── EmailDetailViewModel # Single email display + calendar context detection
│   ├── EmailSummaryViewModel # AI email summaries
│   ├── ComposeViewModel     # Email composition
│   ├── CommandPaletteViewModel # Command palette search/actions (mail + calendar commands)
│   ├── FiltersViewModel       # Gmail filters management
│   ├── EmailActionCoordinator # Email action dispatch
│   ├── PanelCoordinator     # Panel state management
│   ├── AuthViewModel        # Authentication flow
│   ├── AttachmentStore      # Attachment state
│   ├── SyncProgressManager  # Always-visible sync bubble (manual sync trigger + progress)
│   ├── MailStore            # Account/folder state management
│   └── ComposeModeInitializer # Compose mode helpers (structs)
├── Views/                   # SwiftUI components
│   ├── Sidebar/             # Left panel (mode switcher, mini-agenda widget)
│   ├── EmailList/           # Middle panel
│   ├── EmailDetail/         # Right panel (calendar context card, enhanced invite RSVP)
│   ├── Calendar/            # Calendar UI (month/week/day/agenda grids, event detail/editor, mini-month)
│   ├── Common/              # Reusable components (command palette, keyboard shortcuts, quick actions)
│   ├── Components/          # UI building blocks
│   ├── Compose/             # Email composer
│   ├── Attachments/         # Attachment handling
│   ├── Settings/            # Settings UI (general, signatures, filters)
│   └── Onboarding/          # Auth flow UI
├── Intents/                 # App Intents (Shortcuts, Spotlight, Siri)
├── Theme/                   # AppearanceManager, DesignTokens
├── Utilities/               # Pure helpers
└── Resources/               # Assets.xcassets, editor.js
VikTests/                 # Unit tests (root + Database/ + Mocks/ subdirectories)
docs/                       # Architecture docs + superpowers/ specs & plans
.github/workflows/          # CI: release.yml (signing, notarization, DMG)
scripts/                    # release.sh
```

## Dependencies (SPM)
- AppAuth-iOS 1.7.6 — OAuth 2.0
- GRDB.swift 7.10.0 — SQLite database (per-account persistence)

## Data Flow
Services (Gmail API, GRDB database) → ViewModels (@Observable) → Views (SwiftUI)
Views never call Services directly. ViewModels are the single bridge.

## Key Services
- `TrackerBlockerService` — Strips tracking pixels/domains
- `UndoActionManager` — Queued destructive actions with countdown
- `BackgroundSyncer` — Actor for bulk API sync → DB writes
- `FullSyncEngine` — @MainActor class orchestrating email sync: initial full sync, incremental delta sync (History API), body pre-fetch, label refresh, contact refresh
- `CalendarSyncEngine` — Actor (peer to FullSyncEngine) for Google Calendar sync: adaptive polling (15-300s), syncToken incremental (events + calendar list), 410 Gone recovery, post-edit tightening via `temporarilyTightenPolling`
- `CalendarBackgroundSyncer` — Actor for bulk calendar DB writes (upsert events/calendars/attendees)
- `CalendarOfflineActionQueue` — Queues calendar mutations when offline, replays on reconnect with etag conflict detection and automatic 409 conflict resolution (re-fetch + retry)
- `CalendarIntegrationService` — Cross-feature email↔calendar coordination (find events for invites, upcoming meetings with participants)
- `CalendarEventService.rfc3339(_:)` — Shared RFC 3339 date formatter using lightweight `Date.ISO8601FormatStyle` (used by CalendarEventEditorView, CalendarIntents)
- `CalendarEventService` / `CalendarListService` / `CalendarFreeBusyService` — Google Calendar API v3 services
- `LabelSyncService` — Label sync with etag-based caching
- `OfflineActionQueue` — Queues actions when offline, replays on reconnect
- `NetworkMonitor` — Observes network reachability
- `SnoozeStore` / `ScheduledSendStore` — Per-account snooze & schedule-send persistence
- `EmailClassifier` — Apple Intelligence email classification (tags)
- `SummaryService` / `SmartReplyService` — AI-powered features
- `NotificationService` — Push notification handling
- `SpotlightIndexer` / `AttachmentIndexer` — Spotlight & attachment text indexing
- `PerAccountFileStore` — Generic per-account JSON persistence (used by SnoozeStore, ScheduledSendStore, OfflineActionQueue)
- `PeopleAPIService` — Google People API for contacts
- `UnsubscribeService` — Email unsubscribe handling
- `AvatarCache` — Contact avatar caching
- `QuotaTracker` — Gmail API rate-limit tracking
- `BIMIService` — Brand Indicators for Message Identification
- `SignatureResolver` — Email signature resolution
- `ContentExtractor` — Email content extraction
- `EmailPrintService` — Email printing
- `SoundManager` — UI sound effects
- `CPUMonitor` — CPU usage monitoring
- Gmail API layer: `GmailAPIClient` (base), `GmailMessageService`, `GmailLabelService`, `GmailSendService`, `GmailDraftService`, `GmailFilterService`, `GmailProfileService`
