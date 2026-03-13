# Project Overview — Serif

Native macOS Gmail client. Swift 6.2 / SwiftUI. 3-column layout (sidebar, email list, detail). SWIFT_VERSION = 6.2 (Swift 6.2 language mode); Xcode 26.3.

## Target
- macOS 26+
- Xcode 26.3
- Bundle: `com.genyus.serif.app`

## Key Features
- Multi-account Gmail via OAuth 2.0
- Delta sync (Gmail History API)
- Tracker blocking (pixels, domains, CSS)
- Optimistic UI with undo system
- Draft auto-save with 2s debounce
- Theming via @Environment(\.theme)
- GRDB SQLite database for per-account email persistence
- Apple Intelligence integration (summaries, quick replies)

## CI/CD
- GitHub Actions: `v*` tag → build → sign → notarize → DMG → GitHub Release
- Secrets: Google OAuth, Developer ID cert, provisioning profile, Apple notarization credentials

## Build & Test
- Build verification: XcodeBuildMCP
- Tests: `xcodebuild test -scheme Serif -destination 'platform=macOS'`
- Tests in SerifTests/ (root + Database/ subdirectory)
