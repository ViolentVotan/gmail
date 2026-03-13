<p align="center">
  <img src="assets/icon.png" width="128" alt="Serif icon" />
</p>

<h1 align="center">Serif</h1>

<p align="center">
  <em>The email client Gmail deserves on macOS.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B-blue?logo=apple&logoColor=white" />
  <img src="https://img.shields.io/badge/swift-6.2-orange?logo=swift&logoColor=white" />
  <img src="https://img.shields.io/badge/UI-SwiftUI-purple?logo=swift&logoColor=white" />
  <img src="https://img.shields.io/github/v/release/ViolentVotan/gmail?color=green" />
  <img src="https://img.shields.io/github/license/ViolentVotan/gmail" />
</p>

<p align="center">
  <img src="preview.png" alt="App Preview" />
</p>

---

A native macOS Gmail client. No Electron. No web wrapper. Just Swift, SwiftUI, and speed.

**Cache-first.** GRDB SQLite with FTS5 — your inbox loads before you blink.

**Privacy-first.** 180+ tracking domains blocked. No telemetry. Ever.

**Offline-first.** Archive, trash, star, and label emails without a connection — actions sync when you're back online.

**Native-first.** Feels like it shipped with your Mac.

## Features

| | |
|---|---|
| 💬 **Chat-style threads** | Conversations with bubbles, quote collapsing, and thread grouping |
| 🔒 **Tracker blocking** | Spy pixels, tracking links, and CSS trackers — 180+ domains stripped automatically |
| 🔍 **Smart search** | Gmail query syntax + FTS5 local full-text search across your entire mailbox |
| 🤖 **Apple Intelligence** | On-device email summaries, classification, and smart reply suggestions (macOS 26+) |
| ⏰ **Snooze** | Snooze emails to reappear at a time that works for you |
| 📤 **Schedule send** | Write now, send later — schedule messages for the perfect moment |
| 📴 **Offline queue** | Archive, trash, star, label, and more — actions sync when connectivity returns |
| 📅 **Calendar invites** | Event cards with one-click RSVP — accept, decline, maybe |
| ✉️ **One-click unsubscribe** | RFC 8058 compliant. See all your subscriptions in one view |
| 🏷️ **Labels & filters** | Full Gmail label management + filter creation and sync |
| 📎 **Attachment browser** | Browse, search, and preview all attachments with thumbnail caching |
| ⌨️ **Command palette** | `⌘K` to search actions, switch accounts, jump anywhere |
| 🔔 **Notifications** | Native macOS push notifications for new messages |
| 🎙️ **App Intents** | Compose, search, and manage email from Shortcuts, Spotlight, and Siri |
| ✍️ **Signatures** | Per-account signature management synced with Gmail |
| 🖨️ **Print** | Clean HTML-based email printing |
| 🎨 **Appearance** | System, light, and dark modes with Liquid Glass design |
| ⌨️ **Keyboard-first** | `⌘F` search · `⌘N` compose · `⌘E` archive · `⌘⌫` delete · `⌘L` star · `⌘⇧U` read/unread |
| 👥 **Multi-account** | Switch accounts seamlessly, each with its own database and settings |
| 🔄 **Auto-update** | Built-in Sparkle updates with appcast |
| 👤 **Contact avatars** | Google Contacts, Gravatar, and BIMI brand logos |
| ↩️ **Undo send** | Recall recently sent messages before they're delivered |

## Getting Started

```bash
git clone https://github.com/ViolentVotan/gmail.git
```

1. Create a Google Cloud project with **Gmail API** and **People API** enabled, plus an OAuth 2.0 Desktop client
2. Create `Serif/Configuration/GoogleCredentials.swift` with your OAuth client ID and secret (gitignored)
3. Open `Serif.xcodeproj` in **Xcode 26.3+**, build and run

## License

Private project. All rights reserved.
