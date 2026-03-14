# Auto-Select Send-As Alias on Reply

**Date:** 2026-03-14
**Status:** Draft

## Problem

When replying to an email received on a Google Workspace alias, Serif always defaults to the primary account email as the "From" address. Gmail's web client automatically selects the alias the email was addressed to. Users must manually pick the correct alias from the From picker every time.

## Solution

Add a pure utility function that matches an email's To/Cc recipients against the user's send-as aliases, then call it at the two reply entry points in `DetailPaneView` to pass the resolved address downstream.

## Algorithm

`[GmailSendAs].bestAlias(toRecipients:ccRecipients:) -> String?`

1. Normalize all emails to lowercase for comparison
2. Check `To` recipients first — return the first alias whose `sendAsEmail` matches
3. If no To match, check `Cc` recipients — return the first alias match
4. Return `nil` if no match (caller falls back to primary account email)

This matches Gmail web's behavior: To takes priority over Cc; no match falls back to default.

## Files Changed

### New: `Serif/Services/Gmail/GmailSendAs+BestAlias.swift`

Extension on `Array where Element == GmailSendAs` with the `bestAlias(toRecipients:ccRecipients:)` method. Pure function, no side effects, easy to unit test.

### Modified: `Serif/Views/EmailDetail/DetailPaneView.swift`

Two changes:

**1. `emailDetailView(email:)` — ReplyBarView path (line 156)**

Resolve alias before passing `fromAddress` to `EmailDetailView`:

```swift
let resolvedFrom = mailboxViewModel.sendAsAliases.bestAlias(
    toRecipients: email.recipients.map(\.email),
    ccRecipients: email.cc.map(\.email)
) ?? fromAddress
```

Pass `resolvedFrom` instead of `fromAddress` at line 156. This flows through `EmailDetailView` → `ReplyBarView` → `ComposeViewModel.fromAddress`, so the inline reply bar auto-selects the correct alias.

**2. `composeView(draftId:)` — Full compose window path (line 73)**

Resolve alias before passing `fromAddress` to `ComposeView`:

```swift
let resolvedFrom: String = {
    switch composeMode {
    case .reply(_, _, _, _, let threadID),
         .replyAll(_, _, _, _, _, let threadID):
        if let original = mailboxViewModel.emails.first(where: {
            $0.gmailThreadID == threadID
        }) {
            return mailboxViewModel.sendAsAliases.bestAlias(
                toRecipients: original.recipients.map(\.email),
                ccRecipients: original.cc.map(\.email)
            ) ?? fromAddress
        }
        return fromAddress
    default:
        return fromAddress
    }
}()
```

Note: `mailboxViewModel.emails` is used (not `mailStore.emails`) because `mailStore.emails` only contains local drafts. `mailboxViewModel.emails` contains thread-grouped messages from the GRDB database via `ValueObservation`.

Pass `resolvedFrom` instead of `fromAddress` at line 73. This flows into `ComposeView._selectedAliasEmail` and `ComposeViewModel.fromAddress`, so the full compose window also auto-selects the correct alias.

## No Changes Needed

- **`ComposeMode` enum** — stays as-is (no new associated values)
- **`ComposeView`** — already initializes `selectedAliasEmail` from `fromAddress` param; signatures auto-switch via existing `onChange(of: selectedAliasEmail)`
- **`ReplyBarView`** — already creates `ComposeViewModel` from `fromAddress` param
- **`EmailDetailView`** — just passes `fromAddress` through
- **`AppCoordinator.fromAddress`** — stays as the fallback default
- **`GmailSendAs` model** — stays as-is
- **`GmailSendService`** — already sends with whatever `fromAddress` is set
- **Signature handling** — `ComposeView` initializes `selectedAliasEmail` from `fromAddress`; the correct alias-specific signature loads when the mode is applied. Note: `onChange(of: selectedAliasEmail)` doesn't fire for the initial value, so there's a pre-existing edge case where the initial signature may not match if it was set independently (see Edge Cases)

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Single alias (no workspace) | `bestAlias` returns `nil`, falls back to primary — no change |
| Multiple aliases in To/Cc | First match in To wins; if none, first match in Cc |
| Email sent by user (reply to own message) | User's alias likely in sender, not recipients — falls back to primary (correct) |
| Thread lookup misses in ComposeView | Falls back to primary — safe degradation |
| New compose / forward | Mode is `.new` or `.forward` — skips resolution, uses primary |
| Latest thread message is user's own reply | Thread representative's recipients are external contacts, not the user's alias — correctly falls back to primary (matches Gmail web) |
| Signature mismatch with auto-selected alias | Pre-existing: `onChange(of: selectedAliasEmail)` doesn't fire for the initial value. If the preferred reply signature differs from the auto-resolved alias's signature, the initial signature may not match. Acceptable for now; can be addressed separately. |

## Testing

Unit tests for `bestAlias`:
- No aliases → `nil`
- Single alias, match in To → returns alias
- Single alias, match in Cc → returns alias
- Multiple aliases, matches in both To and Cc → To match wins
- Case-insensitive matching
- No match → `nil`
