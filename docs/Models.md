# Models

Pure data structures and local persistence stores.

## Guidelines

- Models are **value types** (`struct`) and conform to `Codable` + `Identifiable`.
- No networking logic. No UI imports (`SwiftUI` only if needed for `Color` or similar).
- Local stores (e.g. `AccountStore`) handle disk persistence via `UserDefaults` or file-based JSON. They do NOT call APIs.
- `Email` is the UI-facing model derived from `GmailMessage`. Conversion happens in `MailboxViewModel`, not here.
- `GmailAccount` holds account metadata + `AccountStore` for multi-account persistence.

## Files

| File | Role |
|------|------|
| `Email.swift` | UI-facing email model (computed from GmailMessage). Synthesized `Equatable` over all stored properties. |
| `Command.swift` | Command palette action model — name, icon, keyboard shortcut, `@Sendable @MainActor` closure. Conforms to `Identifiable` + `Sendable`. |
| `ComposeMode.swift` | Compose mode enum (new, reply, replyAll, forward) |
| `EmailDragItem.swift` | `Transferable` drag item for email rows (custom `UTType` `com.vikingz.serif.email-drag-item`). Conforms to `Codable`, `Transferable`, `Identifiable`, `Sendable`. |
| `EmailTags.swift` | AI classification tags (category, priority, sentiment) for emails |
| `GmailAccount.swift` | Account model + `AccountStore` (UserDefaults persistence). `AccountStore.remove` cleans up all per-account data: TokenStore, MailDatabase, AttachmentDatabase, ContactStore, SnoozeStore, ScheduledSendStore, OfflineActionQueue, UserDefaults (signatures, exclusion rules, reply drafts), AvatarCache. |
| `IndexedAttachment.swift` | Indexed attachment model for the attachment vault |
| `OfflineAction.swift` | Queued mutation model for offline actions (archive, trash, star, unstar, spam, markRead, markUnread, addLabel, removeLabel) with account + message IDs |
| `EmailListActions.swift` | Action struct consolidating email list callbacks (archive, delete, star, bulk ops, etc.) |
| `EmailDetailActions.swift` | Action struct consolidating 24 email detail callbacks (mutations, compose, labels, content). `@MainActor static func contentActions(panelCoordinator:accountID:)` factory builds the shared content-level subset of actions used by both `DetailPaneView` and `SlidePanelsOverlay`. |
| `SnoozePreset` *(in `Views/Common/SnoozePickerView.swift`)* | `Identifiable` struct with `id`, `title`, `icon`, `date` fields. `static func defaults()` returns the standard preset list (tonight, tomorrow, next week, etc.). Defined alongside its view for locality but functions as a shared data model. |
