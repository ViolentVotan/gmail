<p align="center">
  <img src="assets/icon.png" width="128" alt="Serif icon" />
</p>

<h1 align="center">Serif</h1>

<p align="center">
  <em>The email client Gmail deserves on macOS.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?logo=apple&logoColor=white" />
  <img src="https://img.shields.io/badge/swift-5.9-orange?logo=swift&logoColor=white" />
  <img src="https://img.shields.io/badge/UI-SwiftUI-purple?logo=swift&logoColor=white" />
  <img src="https://img.shields.io/github/v/release/marshallino16/Serif?color=green" />
  <img src="https://img.shields.io/github/license/marshallino16/Serif" />
</p>

<p align="center">
  <img src="preview.png" alt="App Preview" />
</p>

---

Serif is a native macOS Gmail client built from scratch with Swift and SwiftUI. No Electron, no web wrapper — just a fast, beautiful, privacy-first email experience that feels right at home on your Mac.

## Why Serif?

- **Instant** — Cache-first architecture. Your inbox loads before you blink.
- **Private** — Tracking pixels blocked by default. No telemetry. Your emails stay yours.
- **Native** — Built with SwiftUI. Smooth animations, keyboard shortcuts, themes — the full macOS experience.
- **Multi-account** — Switch between Gmail accounts seamlessly, each with its own settings.

## Highlights

**Email, done right** — 3-column layout with resizable panes, thread view, swipe actions, bulk operations, and undo on everything.

**Compose like a pro** — Rich text editor with inline images, drag-and-drop attachments, signatures, send-as aliases, and auto-saved drafts.

**Search everything** — Full-text search with Gmail query syntax. Attachment search with smart keyword + semantic matching.

**Calendar invites** — Google Calendar invitations show a clean card with event details and one-click RSVP — no need to leave the app.

**Unsubscribe in one click** — Detects mailing lists and offers RFC 8058 one-click unsubscribe or body link extraction.

**Themes** — 12 built-in themes (light & dark) with per-color overrides. Make it yours.

**Keyboard-driven** — `Cmd+F` to search, `Cmd+Return` to send, `Cmd+Z` to undo. Everything you'd expect.

## Getting Started

1. Clone the repo
2. Open `Serif.xcodeproj` in Xcode 15+
3. Add your Google OAuth credentials in `Serif/Configuration/GoogleCredentials.swift`
4. Build and run (macOS 14.0+)

> You'll need a Google Cloud project with the Gmail API enabled and an OAuth 2.0 Desktop client configured.

## License

Private project. All rights reserved.
