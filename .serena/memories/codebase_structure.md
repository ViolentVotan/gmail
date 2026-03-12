# Codebase Structure — Serif

## Layout
```
Serif/                      # Main app (123 Swift files)
├── SerifApp.swift           # Entry point → OnboardingView or ContentView
├── ContentView.swift        # Main orchestrator (owns ViewModels, wires callbacks)
├── Configuration/           # API keys, OAuth scopes (GoogleCredentials.swift is gitignored)
├── Models/                  # Data models (Email, GmailAccount, MailStore, ComposeMode, IndexedAttachment)
├── Services/                # Business logic & API
│   ├── Auth/                # OAuth & token management (3 files)
│   ├── Gmail/               # Gmail API clients (7 files)
│   └── Protocols/           # Service protocols for testability (2 files)
├── ViewModels/              # @Observable state management (10 files)
│   ├── AppCoordinator       # App-level state coordination
│   ├── MailboxViewModel     # Email list for account+folder
│   ├── EmailDetailViewModel # Single email display
│   ├── ComposeViewModel     # Email composition
│   ├── EmailActionCoordinator # Email action dispatch
│   ├── PanelCoordinator     # Panel state management
│   ├── AuthViewModel        # Authentication flow
│   ├── UpdaterViewModel     # Sparkle auto-update
│   ├── AttachmentStore      # Attachment state
│   └── ComposeModeInitializer # Compose mode helpers (structs)
├── Views/                   # SwiftUI components
│   ├── Sidebar/             # Left panel (3 files)
│   ├── EmailList/           # Middle panel (9 files)
│   ├── EmailDetail/         # Right panel (14 files)
│   ├── Common/              # Reusable components (21 files)
│   ├── Components/          # UI building blocks (3 files)
│   ├── Compose/             # Email composer (2 files)
│   ├── Attachments/         # Attachment handling (3 files)
│   ├── Settings/            # Settings UI (1 file: SignatureEditorView)
│   └── Onboarding/          # Auth flow UI (2 files)
├── Theme/                   # Theming system (4 files: Theme, DefaultThemes, ThemeManager, DesignSystem)
├── Utilities/               # Pure helpers (7 files)
└── Resources/               # Assets.xcassets, Fonts/
SerifTests/                 # Unit tests (11 files)
docs/                       # Architecture docs (9 guides + plans/ + superpowers/)
.github/workflows/          # CI: release.yml (signing, notarization, DMG, Sparkle)
scripts/                    # release.sh
```

## Dependencies (SPM)
- AppAuth-iOS 1.7.6 — OAuth 2.0
- Sparkle 2.9.0 — Auto-updates
- BlossomColorPicker 1.0.0 — Color picker

## Data Flow
Services (Gmail API, disk cache) → ViewModels (@Observable) → Views (SwiftUI)
Views never call Services directly. ViewModels are the single bridge.

## Key Services
- `HistorySyncService` — Delta sync via Gmail History API
- `TrackerBlockerService` — Strips tracking pixels/domains
- `UndoActionManager` — Queued destructive actions with countdown
- `MailCacheStore` — Disk cache keyed by accountID
- `GmailMessageService` / `GmailLabelService` — API clients
