# Serif — Native macOS Gmail Client

Swift 6.2 / SwiftUI / macOS 26+ — a native Gmail client with threading, tracker blocking, multi-account, and Apple Intelligence summaries.

## Fork & Upstream

- **Origin (our fork):** `https://github.com/ViolentVotan/gmail.git`
- **Upstream:** `https://github.com/marshallino16/Serif.git`
- When contributing back upstream, **NEVER include CLAUDE.md** (or any `.claude*` files) in a PR.
- Sync: `git fetch upstream && git merge upstream/master`

## Build & Test

Requires **Xcode 26+** (full IDE, not just command-line tools).

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
├── Views/          # SwiftUI views
├── ViewModels/     # MVVM view models (one per feature)
├── Models/         # Data models
├── Services/       # Business logic (Gmail auth, mail ops, tracking protection)
├── Theme/          # 16 themes (11 dark, 5 light)
├── Configuration/  # OAuth credentials (gitignored)
└── Utilities/      # Helpers
```

**Patterns:** MVVM with coordinator navigation (`AppCoordinator`, `EmailActionCoordinator`). Views talk to ViewModels, not Services directly. `MailStore` handles persistence via JSON. ViewModels and observable classes use `@Observable` macro (not `ObservableObject`). Approachable concurrency with default `MainActor` isolation; `@concurrent` for I/O-bound service methods. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).

## Gotchas

- `GoogleCredentials.swift` must exist locally — app won't build without it
- TokenStore encryption key stored alongside ciphertext (known security issue from review)
- Some computed properties re-sort on every render (performance — see tasks/review.md)
- Views calling Services directly (architecture violation — should go through ViewModels)
- `WebRichTextEditorState` stays as `ObservableObject` — exception to @Observable migration (NSViewRepresentable bridge)
- `UpdaterViewModel` keeps `import Combine` for Sparkle KVO interop

## Task Management

1. **Plan First**: Write plan to 'tasks/todo.md' with checkable items
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review to 'tasks/todo.md'
6. **Capture Lessons**: Update 'tasks/lessons.md' after corrections

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Impact minimal code.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.
- **Autonomous Bug Fixing**: Given a bug report, just fix it — no hand-holding needed.
