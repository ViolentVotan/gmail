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
| `Email.swift` | UI-facing email model (computed from GmailMessage). `messageIDHeader` and `referencesHeader` store RFC 2822 threading headers for reply chain construction. Custom `Equatable` comparing only identity (`id`, `gmailMessageID`) + UI-relevant mutable fields (`isRead`, `isStarred`, `labels`, `gmailLabelIDs`, `preview`, `threadMessageCount`, `tags`, `isDraft`, `gmailDraftID`) — excludes `body`/`subject`/`sender`/`attachments` for performance. `Hashable` conformance uses `id` + `gmailMessageID` (matching Equatable identity fields). `Contact.id` is computed from `email.lowercased()` for deterministic equality. |
| `Command.swift` | Command palette action model — name, icon, keyboard shortcut, `@Sendable @MainActor` closure. Conforms to `Identifiable` + `Sendable`. |
| `ComposeMode.swift` | Compose mode enum (new, reply, replyAll, forward). Reply/replyAll cases include `parentMessageID` and `parentReferences` optional parameters for RFC 2822 threading header chain construction. |
| `EmailDragItem.swift` | `Transferable` drag item for email rows (custom `UTType` `com.vikingz.vik.email-drag-item`). Conforms to `Codable`, `Transferable`, `Identifiable`, `Sendable`. |
| `EmailTags.swift` | AI classification tags (category, priority, sentiment) for emails |
| `GmailAccount.swift` | Account model + `AccountStore` (UserDefaults persistence). `id` is a computed property (`email`) with a doc comment explaining why it is not stored/encoded. Account management: `setAsDefault`, `moveUp`/`moveDown`, `reorder(from:to:)`, `setAccentColor` (wired to Settings + sidebar context menu). `AccountStore.invalidateCache()` clears the in-memory accounts cache. `AccountStore.remove` cleans up per-account data: TokenStore, UnsubscribeService, ContactStore, SnoozeStore, ScheduledSendStore, OfflineActionQueue, LabelSyncService.clearETags, UserDefaults (signatures, exclusion rules, reply drafts, dbMigrationCompleted), AvatarCache. Note: `MailDatabase` and `AttachmentDatabase` are NOT deleted here — `AppCoordinator.handleAccountsChange` stops the sync engine first, then deletes database files to avoid a race. |
| `IndexedAttachment.swift` | Indexed attachment model for the attachment vault |
| `OfflineAction.swift` | Queued mutation model for offline actions (archive, trash, untrash, deletePermanently, star, unstar, spam, markRead, markUnread, addLabel, removeLabel, send) with account + message IDs. `.send(rawBase64URL:threadID:)` carries a pre-built RFC 2822 message for offline send queuing. Custom `Codable` with keyed format for associated-value cases and legacy single-string fallback. |
| `EmailListActions.swift` | `@MainActor` action struct consolidating email list callbacks (archive, delete, star, bulk ops, etc.) |
| `EmailDetailActions.swift` | `@MainActor` action struct consolidating email detail callbacks (mutations, compose, labels, content). `@MainActor static func contentActions(panelCoordinator:accountID:)` factory builds the shared content-level subset of actions used by both `DetailPaneView` and `SlidePanelsOverlay`. |
| `SnoozePreset` *(in `Views/Common/SnoozePickerView.swift`)* | `Identifiable` struct with `id`, `title`, `icon`, `date` fields. `static func defaults()` returns the standard preset list (tonight, tomorrow, next week, etc.). Defined alongside its view for locality but functions as a shared data model. |
