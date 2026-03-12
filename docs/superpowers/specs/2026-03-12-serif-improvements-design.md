# Serif Improvements Design Spec

**Date:** 2026-03-12
**Status:** Draft
**Scope:** Comprehensive improvement plan across 4 phases

## Constraints

- **No push notifications** (Pub/Sub) — out of scope
- **Gmail API only** — no third-party services; leverage native server-side features (categories, importance, spam, filters, search)
- **Apple Intelligence only** — Foundation Models framework, Smart Reply (`UISmartReplySuggestion`), Writing Tools (automatic). No third-party AI/LLM
- **Native Swift/SwiftUI** — all UI in SwiftUI; WKWebView stays for HTML email body rendering (SwiftUI `WebView` unsuitable for email bodies)
- **macOS 26+** — target current SDK; use Liquid Glass, App Intents, Foundation Models

## Feature Ownership Map

Before building anything, we verified what's already provided for free:

| Feature | Provider | Serif Action |
|---------|----------|-------------|
| Email categorization (Primary/Social/Promotions/Updates/Forums) | Gmail server-side (`CATEGORY_*` labels) | Build tab UI only |
| Importance scoring | Gmail server-side (`IMPORTANT` label) | Build priority view only |
| Spam filtering | Gmail server-side (`SPAM` label) | Already done |
| Search | Gmail server-side (`q` parameter) | Already done |
| Server-side filters | Gmail API CRUD | Build management UI only |
| Writing Tools (rewrite/proofread/tone) | Apple Intelligence | Automatic, zero code |
| Notification summaries | Apple Intelligence | Automatic, zero code |
| Priority notifications | Apple Intelligence | Automatic, zero code |
| Inline predictive text | Apple Intelligence | Automatic, zero code |
| Smart Reply suggestions | Apple `UISmartReplySuggestion` | Bridge to SwiftUI |
| Email summarization | Foundation Models (4K context) | Custom code (enhance existing) |
| Snooze | Not in Gmail API | Fully custom client-side |
| Scheduled send | Not in Gmail API | Fully custom client-side |
| Smart Compose (sentence completion) | No API exists anywhere | Out of scope |

---

## Phase 1: "Instant Inbox" — Performance + Gmail Categories

**Goal:** Faster loading, less bandwidth, surface Gmail's free server-side intelligence.

### 1.1 Batch API for Message Fetching

**Current state:** `GmailMessageService.getMessages()` fetches in groups of 5 sequential HTTP calls via `TaskGroup`.

**Design:** Use Gmail's `multipart/mixed` batch API — up to 50 `messages.get` requests in a single HTTP round trip.

**Implementation:**
- New method `GmailAPIClient.batchRequest(requests: [(method: String, path: String, fields: String?)]) -> [(id: String, response: Data)]`
- Constructs `multipart/mixed` body with `Content-Type: application/http` per part
- Parses multi-part response, correlates via `Content-ID` headers
- `GmailMessageService.getMessages(ids:, format:)` calls `batchRequest` instead of chunked loop
- Batch size: 50 (Google's recommended max for rate limit safety)
- Quota: identical to individual calls (N batched = N quota units)
- Error handling: individual parts may fail independently — collect successes, report failures

**Files affected:**
- `Serif/Services/Gmail/GmailAPIClient.swift` — new `batchRequest()` method
- `Serif/Services/Gmail/GmailMessageService.swift` — refactor `getMessages()` to use batch

### 1.2 `fields` Parameter on All API Calls

**Current state:** API responses return full payloads with no field filtering.

**Design:** Add optional `fields` parameter to `GmailAPIClient.request()`, appended as query string.

**Field specifications per endpoint:**
- `messages.list` → `messages(id,threadId),nextPageToken,resultSizeEstimate`
- `messages.get` (metadata format) → `id,threadId,labelIds,snippet,payload/headers,internalDate,sizeEstimate`
- `messages.get` (full format) → `id,threadId,labelIds,snippet,payload,internalDate`
- `threads.get` → `id,messages(id,threadId,labelIds,snippet,payload,internalDate)`
- `labels.list` → `labels(id,name,type,messagesTotal,messagesUnread,threadsTotal,threadsUnread,color,labelListVisibility,messageListVisibility)`
- `history.list` → `history(id,messages(id,labelIds),messagesAdded,messagesDeleted,labelsAdded,labelsRemoved),historyId,nextPageToken`

**Files affected:**
- `Serif/Services/Gmail/GmailAPIClient.swift` — `request()` gains `fields: String?` parameter
- All service files — pass appropriate `fields` values

### 1.3 Gzip Compression Headers

**Design:** Set explicit headers on all requests in `GmailAPIClient`:
- `Accept-Encoding: gzip`
- `User-Agent: Serif/1.0 (gzip)`

URLSession may handle decompression implicitly, but Gmail API docs require these headers for guaranteed server-side gzip.

**Files affected:**
- `Serif/Services/Gmail/GmailAPIClient.swift` — add headers to URLRequest construction

### 1.4 PKCE for OAuth

**Current state:** AppAuth library handles OAuth flow. PKCE status unclear.

**Design:** Verify AppAuth configuration enables PKCE with S256. If not:
- Generate `code_verifier`: 43-128 random chars from `[A-Za-z0-9._~-]`
- Derive `code_challenge` = base64url(SHA256(code_verifier))
- Include `code_challenge` + `code_challenge_method=S256` in authorization request
- Include `code_verifier` in token exchange

AppAuth-iOS supports PKCE natively — likely just needs configuration flag. Verify and fix if needed.

**Files affected:**
- `Serif/Services/Auth/OAuthService.swift` — verify/enable PKCE configuration

### 1.5 Gmail Categories as Split Inbox Tabs

**Current state:** `InboxCategory` enum exists. Categories show in sidebar with unread counts. Messages filtered by `CATEGORY_*` labels.

**Design:** Add tab-style UI at the top of the message list when viewing Inbox.

**UI specification:**
- Horizontal tab bar above message list: Primary | Social | Promotions | Updates | Forums
- Each tab shows unread count badge
- "All" tab option to see everything
- Tabs only visible when viewing Inbox (not other folders)
- Gmail's `IMPORTANT` label surfaced as a toggleable "Priority" filter within any tab
- Category filtering already works — this is purely a UI change

**Files affected:**
- `Serif/Views/EmailList/ListPaneView.swift` — add category tab bar
- `Serif/Views/EmailList/CategoryTabBar.swift` — new view (horizontal tabs with badges)
- `Serif/ViewModels/MailboxViewModel.swift` — minor: expose category switching (likely already exists)

---

## Phase 2: "Time Control" — Snooze + Scheduled Send + Command Palette

**Goal:** Core productivity features every modern email client needs.

### 2.1 Snooze

**Gmail API status:** No snooze endpoint. No `SNOOZED` system label accessible via API. Open feature requests: #109952618, #287304309. Must be fully client-side.

**Mechanism:**
1. User selects snooze time → call `messages.modify` to remove `INBOX` label (archive)
2. Store `{messageId, threadId, accountId, snoozeUntil, originalLabelIds}` in `SnoozeStore`
3. `SnoozeMonitor` (background timer) checks every 60 seconds for expired snoozes
4. On expiry → call `messages.modify` to re-add `INBOX` label
5. On app launch → immediately check and unsnooze any expired items
6. Register `NSBackgroundActivityScheduler` for periodic wake when app is backgrounded

**Persistence:** JSON file per account at `~/Library/Application Support/com.genyus.serif.app/mail-cache/{accountId}/snoozed.json`

**UI specification:**
- Snooze button: `DetailToolbarView` toolbar button + `EmailContextMenu` menu item
- Time picker popover with presets:
  - Later Today (current time + 3 hours, or 6pm if after 3pm)
  - Tomorrow Morning (next day 8:00am)
  - Next Week (next Monday 8:00am)
  - Pick Date & Time (custom `DatePicker`)
- "Snoozed" folder in sidebar (`Folder` enum extension) showing all snoozed items sorted by snooze time
- Snoozed email rows show "Snoozed until [date]" subtitle
- Toast confirmation with undo (via existing `UndoActionManager`)
- Cancel snooze: right-click → "Unsnooze" moves back to inbox immediately

**Edge cases:**
- Message deleted server-side while snoozed → tolerate 404 on unsnooze, remove from store
- Multiple accounts → per-account snooze stores, single `SnoozeMonitor` iterates all
- App not running when snooze expires → unsnooze on next launch + show notification

**New files:**
- `Serif/Services/SnoozeStore.swift` — persistence + CRUD
- `Serif/Services/SnoozeMonitor.swift` — background timer + NSBackgroundActivityScheduler
- `Serif/Views/Common/SnoozePickerView.swift` — time preset popover
- `Serif/Views/Sidebar/SnoozedFolderView.swift` — snoozed items list

**Modified files:**
- `Serif/Models/Folder.swift` — add `.snoozed` case
- `Serif/Views/EmailDetail/DetailToolbarView.swift` — add snooze button
- `Serif/Views/EmailList/EmailContextMenu.swift` — add snooze menu item
- `Serif/Views/Sidebar/SidebarView.swift` — add snoozed folder

### 2.2 Scheduled Send

**Gmail API status:** No `sendAt` parameter on `messages.send` or `drafts.send`. No `SCHEDULED` system label via API. Open feature request: #140922183. Must be fully client-side.

**Mechanism:**
1. User composes email, chooses "Schedule Send" with time
2. Save as Gmail draft via `GmailDraftService` (ensures content is server-side)
3. Store `{draftId, accountId, scheduledTime, subject, recipients}` in `ScheduledSendStore`
4. `ScheduledSendMonitor` checks every 60 seconds (shares timer with `SnoozeMonitor`)
5. On scheduled time → call `drafts.send` via API
6. On app launch → check for past-due scheduled sends, execute immediately, notify user of delay
7. `NSBackgroundActivityScheduler` for periodic wake

**Persistence:** JSON file per account at `~/Library/Application Support/com.genyus.serif.app/mail-cache/{accountId}/scheduled.json`

**UI specification:**
- Split send button in compose: primary "Send" + dropdown chevron revealing "Schedule Send"
- Same time picker as snooze (reuse `SnoozePickerView` with different presets)
- "Scheduled" folder in sidebar showing pending sends sorted by scheduled time
- Edit scheduled: opens compose with draft, cancels the schedule
- Cancel scheduled: right-click → "Cancel Send" deletes from store (draft remains)
- Toast confirmation with undo

**Edge cases:**
- Draft modified in Gmail web while scheduled locally → draft content is server-side, always sends latest version
- App not running at scheduled time → send on next launch + notify user it was delayed
- Network offline at scheduled time → queue in `OfflineActionQueue` (Phase 2.4)

**New files:**
- `Serif/Services/ScheduledSendStore.swift` — persistence
- `Serif/Services/ScheduledSendMonitor.swift` — background timer (or unified with SnoozeMonitor)
- `Serif/Views/Compose/ScheduleSendButton.swift` — split button UI

**Modified files:**
- `Serif/Models/Folder.swift` — add `.scheduled` case
- `Serif/ViewModels/ComposeViewModel.swift` — add `scheduleSend(at:)` method
- `Serif/Views/Sidebar/SidebarView.swift` — add scheduled folder

### 2.3 Command Palette (Cmd+K)

**Current state:** No command palette. Cmd+K is bound to link insertion in `FormattingToolbar` (compose-only, no conflict).

**Design:** Global floating overlay triggered by Cmd+K (when not in compose rich text editor).

**Architecture:**
- `CommandPaletteViewModel` indexes all available commands at launch:
  - **Actions:** Compose, Archive, Delete, Star, Mark Read/Unread, Refresh, Reply, Forward, Print
  - **Folders:** Inbox, Starred, Sent, Drafts, Archive, Spam, Trash, Snoozed, Scheduled
  - **Labels:** All user labels (dynamically loaded per account)
  - **Accounts:** Switch account
  - **Settings:** Open settings, keyboard shortcuts
- Fuzzy string matching (substring + initials) on user input
- Recent commands tracked (last 5)
- Results grouped by category with section headers

**UI specification:**
- Floating panel centered in window (like macOS Spotlight)
- Text field with search icon + "Type a command..." placeholder
- Results list with icons, keyboard shortcut hints, and category headers
- Arrow keys navigate, Enter executes, Escape dismisses
- Max 10 visible results, scrollable
- Subtle blur/glass background

**Keyboard handling:**
- Global `Cmd+K` registered in `SerifCommands` `.commands` modifier
- When compose rich text editor is focused, Cmd+K falls through to link insertion (existing behavior)
- `@FocusState` determines whether palette or editor gets the shortcut

**New files:**
- `Serif/Views/Common/CommandPaletteView.swift` — overlay UI
- `Serif/ViewModels/CommandPaletteViewModel.swift` — command indexing + fuzzy search
- `Serif/Models/Command.swift` — command model (title, icon, shortcut, action closure)

**Modified files:**
- `Serif/Views/ContentView.swift` — add palette overlay + Cmd+K binding
- `Serif/Views/Common/SerifCommands.swift` — register global shortcut

### 2.4 Offline Action Queue

**Current state:** All mutations throw `GmailAPIError.offline` immediately when `NetworkMonitor.shared.isConnected` is false.

**Design:** Queue mutations locally when offline, replay on reconnect.

**Architecture:**
- `OfflineActionQueue` service — actor-based, persists queue as JSON
- Supported actions: archive, delete, star/unstar, mark read/unread, add/remove label, move to spam, move to trash, restore to inbox
- Each action stored as: `{id: UUID, action: ActionType, messageIds: [String], accountId: String, timestamp: Date, params: [String: String]}`
- On `NetworkMonitor` connectivity change to `.connected` → drain queue FIFO
- Per-action error handling: 404 (message gone) → skip silently; 401 → stop queue, trigger re-auth; other → retry with backoff (max 3 attempts)
- Queue persisted at `~/Library/Application Support/com.genyus.serif.app/offline-queue/{accountId}.json`

**UI specification:**
- Small badge on toolbar: "3 pending" when actions are queued
- Offline banner at top of message list: "You're offline. Changes will sync when connected."
- On replay completion: toast "Synced X actions"

**New files:**
- `Serif/Services/OfflineActionQueue.swift` — queue + replay logic
- `Serif/Models/OfflineAction.swift` — action model

**Modified files:**
- `Serif/ViewModels/EmailActionCoordinator.swift` — route through queue when offline
- `Serif/Views/EmailList/ListPaneView.swift` — offline banner

### 2.5 Nudging

**Design:** Subtle visual hint on emails that may need attention.

**Logic:**
- Message is in Inbox
- Older than 3 days
- No reply sent (no message from current account in the same thread after this message's date)
- Not a mailing list / newsletter

**UI:** Small text below the snippet in `EmailRowView`: "Received 3 days ago" in secondary color. No action button — just awareness.

**Files affected:**
- `Serif/Views/EmailList/EmailRowView.swift` — conditional nudge text
- `Serif/ViewModels/MailboxViewModel.swift` — compute nudge eligibility (check thread for sent replies)

---

## Phase 3: "Intelligence" — Smart Reply + Enhanced AI + Filters

**Goal:** Leverage Apple Intelligence APIs and Gmail's server-side filter system.

### 3.1 Smart Reply via `UISmartReplySuggestion`

**Apple API:** `UISmartReplySuggestion` (UIKit). Available on Apple Intelligence-capable hardware. Requires conversation context.

**Design:**
- New `SmartReplyProvider` service wrapping UIKit API via UIViewRepresentable bridge
- Feed thread messages as conversation context (sender, body text, timestamps)
- Returns 2-3 contextual reply suggestions as strings
- Suggestions displayed as tappable chips above the reply bar
- Tapping a chip: opens reply composer pre-filled with the suggestion text
- Availability check: only show chips on supported hardware; fall back gracefully

**Context formatting:** Convert thread messages to the format expected by UISmartReplySuggestion — chronological conversation with sender/body pairs.

**New files:**
- `Serif/Services/SmartReplyProvider.swift` — UIKit bridge + context formatting
- `Serif/Views/EmailDetail/SmartReplyChipsView.swift` — suggestion chip UI

**Modified files:**
- `Serif/Views/EmailDetail/ReplyBarView.swift` — embed chips above reply area
- `Serif/ViewModels/EmailDetailViewModel.swift` — trigger smart reply generation when thread loads

### 3.2 Enhanced Email Summarization (Foundation Models)

**Current state:** `SummaryService` uses Foundation Models with basic text prompting, 200-entry cache, streaming via `AsyncStream<String>`.

**Enhancements:**

**a) Structured output via `@Generable`:**
```swift
@Generable
struct EmailInsight {
    @Guide(description: "2-3 sentence summary of the email content")
    var summary: String

    @Guide(description: "Required action from the recipient, if any. nil if purely informational")
    var actionNeeded: String?

    @Guide(description: "Deadline or time-sensitive date mentioned, if any")
    var deadline: String?

    @Guide(description: "Sentiment: positive, neutral, negative, or urgent")
    var sentiment: String
}
```

**b) Context window management (4,096 token limit):**
- Single message: feed subject + body (truncated to ~3,000 tokens to leave room for output)
- Long threads (>3 messages): chain summarization — summarize oldest messages first as a paragraph, then feed summary + recent 2 messages to the model
- Token estimation heuristic: ~4 chars per token for English

**c) Streaming UI:**
- Use `session.streamResponse(to:, generating: EmailInsight.self)` for progressive fill
- `PartiallyGenerated<EmailInsight>` has optional properties that appear as generated
- UI shows summary first (appears earliest), then action/deadline/sentiment badges fill in

**Modified files:**
- `Serif/Services/SummaryService.swift` — add `@Generable` struct, chain summarization, streaming
- `Serif/Models/EmailInsight.swift` — new model (or inline in SummaryService)
- `Serif/Views/EmailList/EmailHoverSummaryView.swift` — show structured insight
- `Serif/Views/EmailDetail/EmailDetailView.swift` — show insight card in detail view

### 3.3 AI-Powered Classification (Foundation Models)

**Scope:** Only classify what Gmail doesn't already handle. Gmail provides: Primary/Social/Promotions/Updates/Forums categories + IMPORTANT label. We add finer-grained tags.

**Tags (client-side only, not synced to Gmail):**
- `needsReply` — message appears to request a response from the user
- `fyiOnly` — informational, no action needed
- `hasDeadline` — contains a date/time reference for an upcoming event or due date
- `financial` — invoices, receipts, payment requests, bank notifications

**Implementation:**
```swift
@Generable
struct EmailTags {
    @Guide(description: "true if the sender expects a reply from the reader")
    var needsReply: Bool

    @Guide(description: "true if this is purely informational with no action needed")
    var fyiOnly: Bool

    @Guide(description: "true if a specific deadline or due date is mentioned")
    var hasDeadline: Bool

    @Guide(description: "true if this involves money: invoice, receipt, payment, billing")
    var financial: Bool
}
```

- Use `SystemLanguageModel(useCase: .contentTagging)` for classification
- Run in `MessageFetchService.analyzeInBackground()` alongside subscription detection
- Store tags in `MailCacheStore` as metadata per message
- Rate: classify new messages only, skip already-tagged
- Batch: process up to 10 messages per background cycle

**UI:** Small colored badges on email rows (like the existing label chips but smaller). Filterable in command palette ("Show emails needing reply").

**New files:**
- `Serif/Services/EmailClassifier.swift` — classification logic
- `Serif/Models/EmailTags.swift` — tag model

**Modified files:**
- `Serif/Services/MessageFetchService.swift` — call classifier in `analyzeInBackground()`
- `Serif/Services/MailCacheStore.swift` — store/load tags alongside message cache
- `Serif/Views/EmailList/EmailRowView.swift` — show tag badges

### 3.4 Gmail Filters Management UI

**Gmail API:** Full CRUD via `users.settings.filters`. Filters execute server-side. No ML needed — just a management interface.

**API surface:**
- `filters.list` → list all filters
- `filters.get(id)` → get specific filter
- `filters.create(criteria, action)` → create filter
- `filters.delete(id)` → delete filter
- No update — delete + recreate

**Filter criteria:** `from`, `to`, `subject`, `query`, `negatedQuery`, `hasAttachment`, `excludeChats`, `size` + `sizeComparison` (larger/smaller)

**Filter actions:** `addLabelIds`, `removeLabelIds` (archive = remove INBOX, mark read = remove UNREAD, star = add STARRED), `forward` (requires verified email)

**UI specification:**
- New "Filters" tab in Settings alongside existing tabs
- Filter list: each row shows criteria summary + action summary
- Create filter:
  - Step 1: Criteria form (from, to, subject, contains, has attachment, size)
  - Step 2: Action picker (apply label, archive, mark read, star, delete, forward)
  - Preview: "Matches X existing messages" (run search with same criteria)
- Delete filter: confirmation dialog
- "Create filter from this email" in `EmailContextMenu` — pre-fills criteria from message headers

**New files:**
- `Serif/Services/Gmail/GmailFilterService.swift` — API wrapper
- `Serif/Views/Settings/FiltersSettingsView.swift` — filter list
- `Serif/Views/Settings/FilterEditorView.swift` — create/edit form

**Modified files:**
- `Serif/Views/Settings/SettingsView.swift` — add Filters tab
- `Serif/Views/EmailList/EmailContextMenu.swift` — add "Create filter" option

### 3.5 Enable Label Suggestions

**Current state:** `aiLabelSuggestionsEnabled` defaults to `false` in settings. `LabelSuggestionService` exists.

**Design:**
- Enable by default (`aiLabelSuggestionsEnabled = true`)
- Verify it uses Foundation Models (not a removed/broken backend)
- When viewing an email, suggest 1-2 relevant user labels based on content
- Show as subtle chips in `LabelEditorView` with "Suggested" prefix
- User taps to apply; dismiss to ignore
- Learn from dismissals: don't re-suggest the same label for similar content (simple blocklist in cache)

**Modified files:**
- `Serif/ViewModels/MailboxViewModel.swift` or relevant settings — flip default
- `Serif/Services/LabelSuggestionService.swift` — verify/update to use Foundation Models
- `Serif/Views/EmailDetail/LabelEditorView.swift` — verify suggestion chip UI works

---

## Phase 4: "Native Excellence" — Platform Polish

**Goal:** Full macOS 26 design adoption, deep system integration, accessibility.

### 4.1 Liquid Glass Adoption

**Apple guidance (WWDC25 sessions 219, 356, 323, 310):** Liquid Glass is the primary design material for navigation elements. Apps must remove custom backgrounds and let the system apply glass.

**Changes:**

**Sidebar:**
- Remove any `NSVisualEffectView` or custom `.background()` modifiers
- Add `.backgroundExtensionEffect()` to detail content so it extends behind sidebar
- Sidebar automatically floats as Liquid Glass pane via `NavigationSplitView`

**Toolbars:**
- Remove custom background colors, borders, dividers from `DetailToolbarView`
- Group related buttons with `ToolbarItemGroup` (they auto-share glass background)
- Use `ToolbarSpacer(.fixed)` for spacing between groups
- Primary actions (Reply, Send) use `.buttonStyle(.borderedProminent)` for tinted glass
- Add `.badge()` modifiers for unread count indicators

**Scroll edges:**
- Add `.scrollEdgeEffectStyle(.automatic)` on `ScrollView` in list and detail panes
- Remove any manual divider `Divider()` between panes — glass scroll edges replace them

**Window:**
- Add `.windowResizeAnchor(.top)` for fluid resize animation

**Modified files:**
- `Serif/Views/ContentView.swift` — background extension, window modifiers
- `Serif/Views/Sidebar/SidebarView.swift` — remove custom backgrounds
- `Serif/Views/EmailDetail/DetailToolbarView.swift` — toolbar grouping
- `Serif/Views/EmailList/ListPaneView.swift` — scroll edge effects

### 4.2 App Intents for Spotlight & Siri

**Current state:** Basic `CSSearchableItem` indexing in `SpotlightIndexer`.

**Upgrade:** Adopt App Intents framework (macOS 26 recommended approach).

**Entities:**
```swift
struct EmailEntity: IndexedEntity {
    var id: String  // Gmail message ID
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(subject)", subtitle: "\(senderName)")
    }
    // Properties auto-map to Spotlight attributes
}
```

**Intents:**
- `OpenEmailIntent` — opens a specific email by ID (foreground)
- `ComposeEmailIntent` — opens compose window, optionally with recipient (foreground)
- `SearchEmailIntent` — searches inbox with query (foreground)
- `MarkAsReadIntent` — marks email as read (background, no UI)

**Search:** Implement `EntityStringQuery` on `EmailEntity` for deep Spotlight search beyond cached suggestions.

**Migration:** `SpotlightIndexer` switches from raw `CSSearchableItem` to `IndexedEntity`. Existing indexed items are replaced on first run.

**New files:**
- `Serif/Intents/EmailEntity.swift` — entity definition
- `Serif/Intents/OpenEmailIntent.swift` — open email
- `Serif/Intents/ComposeEmailIntent.swift` — compose
- `Serif/Intents/SearchEmailIntent.swift` — search
- `Serif/Intents/MarkAsReadIntent.swift` — mark read

**Modified files:**
- `Serif/Services/SpotlightIndexer.swift` — migrate to IndexedEntity

### 4.3 Handoff Completion

**Current state:** Commit 48fa028 mentions Handoff but `NSUserActivity` code not found.

**Implementation:**
- When viewing an email thread: create/update `NSUserActivity`
  - `activityType`: `"com.genyus.serif.viewEmail"`
  - `title`: email subject
  - `userInfo`: `["threadId": threadId, "accountId": accountId]`
  - `isEligibleForHandoff = true`
  - `isEligibleForSearch = true`
- When composing: separate activity type `"com.genyus.serif.composeEmail"`
- Handle incoming activity: `AppCoordinator` navigates to thread/compose on `onContinueUserActivity`
- Register activity types in `Info.plist` under `NSUserActivityTypes`

**Modified files:**
- `Serif/ViewModels/EmailDetailViewModel.swift` — create NSUserActivity on thread load
- `Serif/ViewModels/ComposeViewModel.swift` — create NSUserActivity on compose
- `Serif/Views/ContentView.swift` — handle `onContinueUserActivity`
- `Info.plist` — register activity types

### 4.4 Actionable Local Notifications

**Design:** Generate local notifications for new emails detected during refresh, with quick actions.

**Notification categories:**
```swift
let replyAction = UNTextInputNotificationAction(
    identifier: "REPLY", title: "Reply",
    textInputButtonTitle: "Send", textInputPlaceholder: "Type reply..."
)
let archiveAction = UNNotificationAction(identifier: "ARCHIVE", title: "Archive")
let markReadAction = UNNotificationAction(identifier: "MARK_READ", title: "Mark Read")

let emailCategory = UNNotificationCategory(
    identifier: "NEW_EMAIL",
    actions: [replyAction, archiveAction, markReadAction],
    intentIdentifiers: []
)
```

**Notification content:**
- `title`: sender name
- `subtitle`: subject line
- `body`: snippet (first ~100 chars)
- `threadIdentifier`: Gmail thread ID (auto-groups by conversation)
- `summaryArgument`: sender name (for Apple Intelligence summaries: "3 more from John")
- `summaryArgumentCount`: 1

**Trigger:** `HistorySyncService` detects new `messagesAdded` → generate notification for each new inbox message. Rate limit: max 5 notifications per sync cycle (batch remainder into summary).

**Settings:** Respect existing notification preferences. Add toggle in Settings: "Show notifications for new emails" (default: on).

**New files:**
- `Serif/Services/NotificationService.swift` — category registration, notification generation, action handling

**Modified files:**
- `Serif/Services/HistorySyncService.swift` — trigger notifications on new messages
- `Serif/Views/Settings/SettingsView.swift` — notification toggle
- `Serif/SerifApp.swift` — register notification categories on launch, set delegate

### 4.5 Accessibility Improvements

**Custom rotors (VoiceOver quick navigation):**
```swift
.accessibilityRotor("Unread Emails") {
    ForEach(unreadEmails) { email in
        AccessibilityRotorEntry(email.subject, id: email.id)
    }
}
.accessibilityRotor("Starred") { ... }
.accessibilityRotor("Has Attachments") { ... }
```

**Element combination on email rows:**
- `.accessibilityElement(children: .combine)` on `EmailRowView` container
- Read order: sender, subject, snippet, date (via `accessibilitySortPriority`)
- Star state included: "Starred" / "Not starred"

**Focus management:**
- `accessibilityDefaultFocus` on message list when navigating to a folder
- Clear focus announcements on folder switch

**Quick actions via VoiceOver:**
- `.accessibilityAction(named: "Archive")` on email rows
- `.accessibilityAction(named: "Star")` on email rows
- `.accessibilityAction(named: "Mark as Read")` on email rows

**Modified files:**
- `Serif/Views/EmailList/EmailRowView.swift` — combine, sort priority, actions
- `Serif/Views/EmailList/EmailListView.swift` — rotors, default focus
- `Serif/Views/Sidebar/SidebarView.swift` — rotor for folders
- `Serif/Views/EmailDetail/EmailDetailView.swift` — detail accessibility

### 4.6 Drag and Drop

**Design:**
- **Drag emails to labels:** Drag from message list → drop on sidebar label row → apply label
- **Drag to special folders:** Drag → drop on Trash/Archive/Spam → move
- **Multi-select drag:** `.draggable(containerItemID:)` + `.dragContainer(for:, selection:)` with selection from `EmailSelectionManager`
- **Drag preview:** `.dragPreviewsFormation(.stack)` for multi-item visual stacking
- **Drag attachments:** From detail view attachment chips → drag to Finder/Desktop as file

**Drop targets:**
- Sidebar label rows: `.dropDestination(for: EmailDragItem.self)` → call `messages.modify` to add label
- Sidebar special folders: `.dropDestination` → archive/trash/spam action
- Desktop/Finder: attachment drag provides `NSItemProvider` with file data

**New files:**
- `Serif/Models/EmailDragItem.swift` — transferable drag payload

**Modified files:**
- `Serif/Views/EmailList/EmailRowView.swift` — `.draggable()` modifier
- `Serif/Views/EmailList/EmailListView.swift` — `.dragContainer()` for selection-aware drag
- `Serif/Views/Sidebar/SidebarView.swift` — `.dropDestination()` on label/folder rows
- `Serif/Views/EmailDetail/AttachmentChipView.swift` — `.draggable()` with file data

### 4.7 Undo Send (Send Delay)

**Current state:** `ComposeViewModel.send()` calls `GmailSendService.send()` immediately. `UndoActionManager` exists with configurable duration (5/10/20/30 sec).

**Design:** Route send through existing undo infrastructure.

**Mechanism:**
1. User presses Send → `ComposeViewModel` registers action with `UndoActionManager`
2. Undo toast appears with countdown (existing `UndoToastView`)
3. If user presses Undo → cancel send, reopen compose with draft intact
4. If timer expires → execute `GmailSendService.send()`
5. Close compose window only after successful send (not on button press)

**UI change:** Compose window stays open during countdown with a "Sending in X seconds..." banner and "Undo" button. Closes automatically after send succeeds.

**Modified files:**
- `Serif/ViewModels/ComposeViewModel.swift` — route send through `UndoActionManager`
- `Serif/Views/Compose/ComposeView.swift` — sending state UI with countdown

---

## Phase Dependencies

```
Phase 1 (Instant Inbox) ← no dependencies
    ↓
Phase 2 (Time Control) ← benefits from batch API (Phase 1)
    ↓
Phase 3 (Intelligence) ← can run parallel with Phase 2
    ↓
Phase 4 (Native Excellence) ← notifications benefit from sync (Phase 1-2)
```

Phases 2 and 3 are independent and can be developed in parallel.
Phase 4 items are all independent of each other and can be parallelized.

## File Impact Summary

**New files (estimated 22):**
- Services: 8 (SnoozeStore, SnoozeMonitor, ScheduledSendStore, ScheduledSendMonitor, OfflineActionQueue, SmartReplyProvider, EmailClassifier, NotificationService, GmailFilterService)
- Views: 8 (CategoryTabBar, SnoozePickerView, CommandPaletteView, ScheduleSendButton, SmartReplyChipsView, FiltersSettingsView, FilterEditorView, SnoozedFolderView)
- ViewModels: 1 (CommandPaletteViewModel)
- Models: 4 (Command, OfflineAction, EmailTags, EmailDragItem, EmailInsight)
- Intents: 5 (EmailEntity, OpenEmailIntent, ComposeEmailIntent, SearchEmailIntent, MarkAsReadIntent)

**Modified files (estimated 25):**
- Services: 6 (GmailAPIClient, GmailMessageService, MessageFetchService, MailCacheStore, SummaryService, HistorySyncService, SpotlightIndexer, OAuthService)
- Views: 12 (ContentView, SidebarView, ListPaneView, DetailToolbarView, EmailRowView, EmailContextMenu, EmailListView, ReplyBarView, ComposeView, SettingsView, EmailDetailView, AttachmentChipView)
- ViewModels: 4 (MailboxViewModel, ComposeViewModel, EmailDetailViewModel, EmailActionCoordinator)
- Models: 1 (Folder)
- Config: 1 (Info.plist)
- Commands: 1 (SerifCommands)

## Out of Scope

- Push notifications (Gmail Pub/Sub) — excluded per user request
- Smart Compose / sentence completion — no API exists from Apple or Gmail
- Calendar event creation — separate feature domain
- Task/reminder integration — separate feature domain
- End-to-end encryption — Gmail API doesn't support it
- Third-party AI services — Apple Intelligence only
