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
| `Email.swift` | UI-facing email model (computed from GmailMessage) |
| `GmailAccount.swift` | Account model + `AccountStore` (UserDefaults persistence) |
| `MailStore.swift` | Local draft store, Gmail draft sync, reply draft persistence (`ReplyDraftInfo`) |
| `EmailLabel.swift` | Label model with name and color |
| `Attachment.swift` | Attachment model (name, size, MIME type, Gmail IDs) |
