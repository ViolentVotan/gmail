# Auto-Select Send-As Alias on Reply — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically select the correct "From" alias when replying to emails received on a Google Workspace send-as alias, matching Gmail web's behavior.

**Architecture:** A pure extension method on `[GmailSendAs]` resolves the best alias by matching email To/Cc recipients. Called at two sites in `DetailPaneView` to pass the resolved address downstream — no changes to `ComposeMode`, `ComposeView`, `ReplyBarView`, or the send path.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing

**Spec:** `docs/superpowers/specs/2026-03-14-auto-alias-reply-design.md`

---

## Task 1: Utility function — `bestAlias`

**Files:**
- Create: `Serif/Services/Gmail/GmailSendAs+BestAlias.swift`
- Test: `SerifTests/GmailSendAsBestAliasTests.swift`

- [ ] **Step 1: Write failing tests**

Create `SerifTests/GmailSendAsBestAliasTests.swift`:

```swift
import Testing
@testable import Serif

@Suite struct GmailSendAsBestAliasTests {

    private let aliases: [GmailSendAs] = [
        GmailSendAs(sendAsEmail: "primary@example.com", displayName: "Primary", signature: nil, isDefault: true, isPrimary: true),
        GmailSendAs(sendAsEmail: "alias@example.com", displayName: "Alias", signature: nil, isDefault: false, isPrimary: false),
        GmailSendAs(sendAsEmail: "work@company.com", displayName: "Work", signature: nil, isDefault: false, isPrimary: false),
    ]

    @Test func noAliases_returnsNil() {
        let empty: [GmailSendAs] = []
        #expect(empty.bestAlias(toRecipients: ["anyone@test.com"], ccRecipients: []) == nil)
    }

    @Test func matchInTo_returnsAlias() {
        let result = aliases.bestAlias(toRecipients: ["alias@example.com"], ccRecipients: [])
        #expect(result == "alias@example.com")
    }

    @Test func matchInCc_returnsAlias() {
        let result = aliases.bestAlias(toRecipients: ["stranger@test.com"], ccRecipients: ["work@company.com"])
        #expect(result == "work@company.com")
    }

    @Test func toTakesPriorityOverCc() {
        let result = aliases.bestAlias(
            toRecipients: ["alias@example.com"],
            ccRecipients: ["work@company.com"]
        )
        #expect(result == "alias@example.com")
    }

    @Test func caseInsensitiveMatching() {
        let result = aliases.bestAlias(toRecipients: ["ALIAS@Example.COM"], ccRecipients: [])
        #expect(result == "alias@example.com")
    }

    @Test func noMatch_returnsNil() {
        let result = aliases.bestAlias(toRecipients: ["unknown@test.com"], ccRecipients: ["other@test.com"])
        #expect(result == nil)
    }

    @Test func emptyRecipients_returnsNil() {
        let result = aliases.bestAlias(toRecipients: [], ccRecipients: [])
        #expect(result == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Serif -destination 'platform=macOS' test 2>&1 | grep -E '(Test.*FAIL|error:.*bestAlias|Build FAILED)'`
Expected: Build fails — `bestAlias` not defined.

- [ ] **Step 3: Write the implementation**

Create `Serif/Services/Gmail/GmailSendAs+BestAlias.swift`:

```swift
extension Array where Element == GmailSendAs {
    /// Returns the `sendAsEmail` of the best matching alias for a received email,
    /// checking To recipients first, then Cc. Returns `nil` if no alias matches.
    func bestAlias(toRecipients: [String], ccRecipients: [String]) -> String? {
        // Priority 1: match in To
        for recipient in toRecipients {
            if let alias = first(where: { $0.sendAsEmail.caseInsensitiveCompare(recipient) == .orderedSame }) {
                return alias.sendAsEmail
            }
        }
        // Priority 2: match in Cc
        for recipient in ccRecipients {
            if let alias = first(where: { $0.sendAsEmail.caseInsensitiveCompare(recipient) == .orderedSame }) {
                return alias.sendAsEmail
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Serif -destination 'platform=macOS' test 2>&1 | grep -E '(GmailSendAsBestAlias|PASS|FAIL)'`
Expected: All 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Serif/Services/Gmail/GmailSendAs+BestAlias.swift SerifTests/GmailSendAsBestAliasTests.swift
git commit -m "feat: add bestAlias utility for send-as alias resolution"
```

---

## Task 2: Wire alias resolution into DetailPaneView

**Files:**
- Modify: `Serif/Views/EmailDetail/DetailPaneView.swift:68-84` (composeView) and `Serif/Views/EmailDetail/DetailPaneView.swift:149-158` (emailDetailView)

**Depends on:** Task 1

- [ ] **Step 1: Add helper method to DetailPaneView**

Add a private method after the convenience accessors (after line 22):

```swift
/// Resolves the best send-as alias for the given email, falling back to the primary account address.
private func resolvedFromAddress(for email: Email) -> String {
    mailboxViewModel.sendAsAliases.bestAlias(
        toRecipients: email.recipients.map(\.email),
        ccRecipients: email.cc.map(\.email)
    ) ?? fromAddress
}
```

- [ ] **Step 2: Update `emailDetailView(email:)` — ReplyBarView path**

At line 156, change `fromAddress: fromAddress` to `fromAddress: resolvedFromAddress(for: email)`.

Before:
```swift
fromAddress: fromAddress,
```
After:
```swift
fromAddress: resolvedFromAddress(for: email),
```

- [ ] **Step 3: Update `composeView(draftId:)` — full compose window path**

Replace line 73 (`fromAddress: fromAddress,`) with alias resolution using the thread ID from `composeMode`:

Before:
```swift
private func composeView(draftId: UUID) -> some View {
    ComposeView(
        mailStore: mailStore,
        draftId: draftId,
        accountID: accountID,
        fromAddress: fromAddress,
```

After:
```swift
private func composeView(draftId: UUID) -> some View {
    let resolvedFrom: String = {
        switch composeMode {
        case .reply(_, _, _, _, let threadID),
             .replyAll(_, _, _, _, _, let threadID):
            if let original = mailboxViewModel.emails.first(where: { $0.gmailThreadID == threadID }) {
                return resolvedFromAddress(for: original)
            }
            return fromAddress
        default:
            return fromAddress
        }
    }()

    return ComposeView(
        mailStore: mailStore,
        draftId: draftId,
        accountID: accountID,
        fromAddress: resolvedFrom,
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Run full test suite**

Run: `xcodebuild -scheme Serif -destination 'platform=macOS' test 2>&1 | grep -E '(Test Suite|passed|failed)'`
Expected: All tests pass (including the new ones from Task 1).

- [ ] **Step 6: Commit**

```bash
git add Serif/Views/EmailDetail/DetailPaneView.swift
git commit -m "feat: auto-select send-as alias when replying to emails"
```
