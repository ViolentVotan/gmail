# Codebase Structure — Serif

## Layout
```
Serif/                      # Main app
├── SerifApp.swift           # Entry point → OnboardingView or ContentView
├── ContentView.swift        # Main orchestrator (owns ViewModels, wires callbacks)
├── Configuration/           # API keys, OAuth scopes (GoogleCredentials.swift is gitignored)
├── Database/                # GRDB SQLite persistence (per-account)
│   ├── Records/             # GRDB record types (MessageRecord, LabelRecord, etc.)
│   ├── MailDatabase.swift
│   ├── MailDatabaseMigrations.swift
│   ├── MailDatabaseQueries.swift
│   ├── FTSManager.swift
│   └── CacheMigration.swift
├── Models/                  # Data models (Email, GmailAccount, MailStore, ComposeMode, etc.)
├── Services/                # Business logic & API
│   ├── Auth/                # OAuth & token management
│   ├── Gmail/               # Gmail API clients
│   └── Protocols/           # Service protocols for testability
├── ViewModels/              # @Observable state management
│   ├── AppCoordinator       # App-level state coordination
│   ├── MailboxViewModel     # Email list for account+folder
│   ├── EmailDetailViewModel # Single email display
│   ├── EmailSummaryViewModel # AI email summaries
│   ├── ComposeViewModel     # Email composition
│   ├── CommandPaletteViewModel # Command palette search/actions
│   ├── FiltersViewModel       # Gmail filters management
│   ├── EmailActionCoordinator # Email action dispatch
│   ├── PanelCoordinator     # Panel state management
│   ├── AuthViewModel        # Authentication flow
│   ├── AttachmentStore      # Attachment state
│   └── ComposeModeInitializer # Compose mode helpers (structs)
├── Views/                   # SwiftUI components
│   ├── Sidebar/             # Left panel
│   ├── EmailList/           # Middle panel
│   ├── EmailDetail/         # Right panel
│   ├── Common/              # Reusable components
│   ├── Components/          # UI building blocks
│   ├── Compose/             # Email composer
│   ├── Attachments/         # Attachment handling
│   ├── Settings/            # Settings UI (general, signatures, filters)
│   └── Onboarding/          # Auth flow UI
├── Intents/                 # App Intents (Shortcuts, Spotlight, Siri)
├── Theme/                   # AppearanceManager, DesignTokens
├── Utilities/               # Pure helpers
└── Resources/               # Assets.xcassets, Fonts/
SerifTests/                 # Unit tests (root + Database/ subdirectory)
docs/                       # Architecture docs + superpowers/ specs & plans
.github/workflows/          # CI: release.yml (signing, notarization, DMG)
scripts/                    # release.sh
```

## Dependencies (SPM)
- AppAuth-iOS 1.7.6 — OAuth 2.0
- GRDB.swift 7.10.0 — SQLite database (per-account persistence)
- BlossomColorPicker 1.0.0 — Color picker

## Data Flow
Services (Gmail API, GRDB database) → ViewModels (@Observable) → Views (SwiftUI)
Views never call Services directly. ViewModels are the single bridge.

## Key Services
- `HistorySyncService` — Delta sync via Gmail History API
- `TrackerBlockerService` — Strips tracking pixels/domains
- `UndoActionManager` — Queued destructive actions with countdown
- `BackgroundSyncer` — Actor for bulk API sync → DB writes
- `OfflineActionQueue` — Queues actions when offline, replays on reconnect
- `NetworkMonitor` — Observes network reachability
- `SnoozeStore` / `ScheduledSendStore` — Per-account snooze & schedule-send persistence
- `EmailClassifier` — Apple Intelligence email classification (tags)
- `SummaryService` / `SmartReplyProvider` / `QuickReplyService` — AI-powered features
- `NotificationService` — Push notification handling
- `SpotlightIndexer` / `AttachmentIndexer` — Spotlight & attachment text indexing
- Gmail API layer: `GmailAPIClient` (base), `GmailMessageService`, `GmailLabelService`, `GmailSendService`, `GmailDraftService`, `GmailFilterService`, `GmailProfileService`
