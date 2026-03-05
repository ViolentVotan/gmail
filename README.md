# Serif

A native macOS Gmail client built with Swift and SwiftUI. Serif delivers a clean, fast, and privacy-focused email experience with a modern 3-column layout.

## Features

### Email Management
- **3-column layout** — Sidebar, email list, and detail pane with resizable columns
- **Full Gmail integration** — Inbox, Starred, Sent, Drafts, Archive, Spam, Trash
- **Inbox categories** — Primary, Social, Promotions, Updates, Forums
- **Custom labels** — Create, rename, delete, and assign labels with color coding
- **Thread view** — Full conversation display with inline message expansion
- **Swipe actions** — Swipe to archive or delete from the email list
- **Bulk operations** — Multi-select with archive, delete, star, mark read/unread
- **Undo system** — Toast notification with configurable countdown to undo actions

### Compose & Drafts
- **Rich text editor** — Bold, italic, underline, strikethrough, font size, text color, headings, lists, links, alignment
- **Inline images** — Paste or drag-and-drop images directly into the editor
- **File attachments** — Attach files via picker or drag-and-drop
- **Compose modes** — New, Reply, Reply All, Forward
- **Send-as aliases** — Switch sender address from multiple aliases
- **Signatures** — Separate signatures for new messages and replies
- **Auto-save drafts** — Debounced auto-save to Gmail with draft persistence
- **Quick reply** — Inline reply bar with draft persistence across sessions
- **Contact autocomplete** — Suggestions from cached contacts in To/Cc/Bcc fields
- **Discard confirmation** — Alert before permanently deleting drafts

### Search
- **Full-text search** — Search across all emails with Gmail query syntax support
- **Attachment search** — Hybrid keyword (FTS5) + semantic embedding search
- **Filter by file type** — Images, documents, PDFs, spreadsheets, archives

### Attachments
- **Attachment explorer** — Dedicated grid view with thumbnails
- **Background indexing** — CPU-throttled batch processing with adaptive concurrency
- **Content extraction** — Text, OCR for images/PDFs, Office document parsing
- **Semantic search** — ML-based embedding generation for intelligent search
- **Exclusion rules** — Per-account patterns to skip during indexing

### Privacy & Security
- **Tracker blocking** — Blocks tracking pixels, known tracker domains, and CSS background trackers
- **HTML sanitization** — Removes malicious content from email HTML
- **BIMI logos** — Verified sender logos via DNS-over-HTTPS
- **Unsubscribe** — One-click RFC 8058 unsubscribe + body link detection
- **Sandboxed** — App Sandbox with minimal entitlements

### Sync & Performance
- **Delta sync** — Incremental updates via Gmail History API
- **Cache-first** — Disk-based cache for instant offline access
- **Stale detection** — Verifies cached messages still exist on Gmail
- **Network monitoring** — Online/offline status detection
- **Configurable refresh** — 2, 5, 10 minutes or 1 hour intervals

### Theming
- **12 built-in themes** — Light, Dark, and various styled themes
- **Per-theme color overrides** — Customize individual colors within any theme
- **Design system** — Consistent typography, spacing, and component styling

### Multi-Account
- **Multiple Gmail accounts** — Switch between accounts with full data isolation
- **Per-account settings** — Signatures, exclusion rules, contacts, send-as aliases
- **Secure token storage** — OAuth tokens persisted in macOS Keychain

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift |
| UI Framework | SwiftUI |
| Platform | macOS 14.0+ (Sonoma) |
| Auth | Google OAuth 2.0 via [AppAuth](https://github.com/openid/AppAuth-iOS) |
| Email API | Gmail REST API |
| Email Rendering | WKWebView |
| Rich Text Editor | Web-based HTML editor (WKWebView) |
| Token Storage | macOS Keychain |
| Cache | File-based JSON (`~/Library/Application Support/`) |
| Attachment Index | SQLite with FTS5 |
| Search | Hybrid FTS + semantic embeddings |

## Architecture

Serif follows **MVVM with a Service layer**:

```
Views (SwiftUI)
  |
ViewModels (@MainActor ObservableObject)
  |
Services (singletons — networking, business logic)
  |
Models (value types — data, persistence)
```

**Core principles:**
- **Unidirectional data flow** — Services -> ViewModels -> Views
- **Cache-first** — Load from disk, show instantly, refresh from API
- **Optimistic UI** — Mutations update UI immediately, then call the API
- **Theme via Environment** — `@Environment(\.theme)` for all colors
- **Multi-account aware** — All data keyed by `accountID`

## Project Structure

```
Serif/
├── Configuration/     # OAuth credentials, API scopes
├── Models/            # Data models (Email, Contact, GmailAccount, MailStore)
├── Services/
│   ├── Auth/          # OAuth flow, token storage (Keychain)
│   └── Gmail/         # API client, messages, labels, send, drafts, profiles
├── Theme/             # Theme system (12 themes, overrides, persistence)
├── Utilities/         # Pure helpers (date formatting, MIME parsing, transformers)
├── ViewModels/        # State management (Auth, Mailbox, EmailDetail, Compose)
├── Views/
│   ├── Sidebar/       # Folder navigation, account switcher, labels
│   ├── EmailList/     # Email rows, swipe actions, search, pull-to-refresh
│   ├── EmailDetail/   # Thread view, HTML rendering, reply bar, attachments
│   ├── Compose/       # Rich text editor, autocomplete, formatting toolbar
│   ├── Attachments/   # Attachment explorer grid
│   ├── Onboarding/    # Sign-in flow
│   └── Common/        # Shared components (Avatar, Toast, SlidePanel, etc.)
└── Resources/         # Assets, fonts
```

## Setup

1. Clone the repository
2. Open `Serif.xcodeproj` in Xcode 15+
3. Add your Google OAuth credentials in `Serif/Configuration/GoogleCredentials.swift`
4. Build and run (macOS 14.0+)

### OAuth Configuration

Create a Google Cloud project with the Gmail API enabled and configure an OAuth 2.0 Desktop client. Set the redirect URI scheme to match your bundle identifier.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd + ,` | Settings |
| `Cmd + F` | Focus search |
| `Cmd + A` | Select all emails |
| `Cmd + Z` | Undo last action |
| `Cmd + Return` | Send email |
| `Esc` | Close panel / Discard reply |

## License

Private project. All rights reserved.
