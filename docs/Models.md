# Models

Pure data structures and local persistence stores.

## Guidelines

- Models are **value types** (`struct`) and conform to `Codable` + `Identifiable`.
- No networking logic. No UI imports (`SwiftUI` only if needed for `Color` or similar).
- Local stores (e.g. `MailStore`, `AccountStore`) handle disk persistence via `UserDefaults` or file-based JSON. They do NOT call APIs.
- `Email` is the UI-facing model derived from `GmailMessage`. Conversion happens in `MailboxViewModel`, not here.
- `GmailAccount` holds account metadata + `AccountStore` for multi-account persistence.

## Files

| File | Role |
|------|------|
| `Email.swift` | UI-facing email model (computed from GmailMessage). Synthesized `Equatable` over all stored properties. |
| `Command.swift` | Command palette action model — name, icon, keyboard shortcut, closure |
| `ComposeMode.swift` | Compose mode enum (new, reply, replyAll, forward) |
| `EmailDragItem.swift` | `Transferable` drag item for email rows (custom `UTType` `com.genyus.serif.email-drag-item`) |
| `EmailTags.swift` | AI classification tags (category, priority, sentiment) for emails |
| `GmailAccount.swift` | Account model + `AccountStore` (UserDefaults persistence) |
| `IndexedAttachment.swift` | Indexed attachment model for the attachment vault |
| `MailStore.swift` | `@Observable @MainActor` local draft store, Gmail draft sync, reply draft persistence (`ReplyDraftInfo`) |
| `OfflineAction.swift` | Queued mutation model for offline actions (archive, trash) with account + message IDs |
| `EmailListActions.swift` | Action struct consolidating 23 email list callbacks (archive, delete, star, bulk ops, etc.) |
| `EmailDetailActions.swift` | Action struct consolidating 24 email detail callbacks (mutations, compose, labels, content) |
