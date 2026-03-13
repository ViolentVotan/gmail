# Collapsible Conversation Cards — Design Spec

**Date:** 2026-03-14
**Status:** Draft
**Scope:** Redesign email thread display from chat bubbles to collapsible conversation cards

---

## Problem

The current thread view uses a split display model: the latest message gets full-width hero treatment, while older messages render as chat bubbles (iMessage-style, left/right aligned, max 500pt). For long exchanges (10+ messages), this creates an unnavigable wall of fully-rendered content with no hierarchy, no scanning, and a semantic mismatch (email is not instant messaging).

## Solution

Replace the entire thread display with a **unified chronological list of collapsible message cards**. The most recent message is expanded by default; all others are collapsed. Users can expand/collapse any card by clicking its header. Multiple cards can be open simultaneously, with a "Collapse All" action to reset.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Card architecture | Unified — all messages use the same card component | Eliminates the hero/bubble split; consistent, maintainable |
| Message order | Chronological (oldest first, newest last) | Matches natural reading order; Gmail web, Superhuman, Spark precedent |
| Expansion behavior | Multi-open with "Collapse All" | Flexible for comparing messages; escape hatch when thread gets unwieldy |
| Liquid Glass on cards | No | Apple HIG: "Don't use Liquid Glass in the content layer" |
| Chat bubbles | Removed | Email is not instant messaging; bubbles waste horizontal space and look informal |
| WebView instantiation | Only for expanded cards | Collapsed cards use plain-text snippet; major performance improvement |

## Thread-Level Layout

```
ScrollViewReader { proxy in
    ScrollView {
        VStack(alignment: .leading, spacing: 0) {

            // Thread metadata (unchanged from current)
            Subject line + ellipsis menu
            Label chips + AI suggestions
            Insight card (macOS 26+)
            Tracker banner (if blocked)
            Calendar invite card (if detected)

            // Conversation header (NEW)
            "N messages" label + "Collapse All" button

            // Conversation cards (NEW)
            LazyVStack(spacing: 1) {
                ForEach(allMessagesChronological) { message in
                    ThreadMessageCardView(...)
                        .id(message.id)
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
    .onAppear { proxy.scrollTo(latestMessageID, anchor: .bottom) }
}

// Reply bar stays as safeAreaInset(edge: .bottom)
```

### Changes from current layout

- **Removed:** Large sender header (40pt avatar + name + email + date) at top level — each card now has its own compact header
- **Removed:** Separate hero rendering of latest message body
- **Removed:** `conversationSection` with chat bubbles
- **Added:** Conversation header row with message count and "Collapse All"
- **Added:** Unified `LazyVStack` of `ThreadMessageCardView` cards
- **Kept:** Subject, labels, insights, tracker banner, calendar invite, reply bar — all unchanged

## ThreadMessageCardView

### Collapsed State (~48pt height)

```
┌─────────────────────────────────────────────────────────────────┐
│  [Avatar 24]  Sender Name    snippet of message...    2:30 PM  │
└─────────────────────────────────────────────────────────────────┘
```

| Element | Spec |
|---------|------|
| Avatar | 24pt, existing `AvatarView` |
| Sender name | `Typography.calloutSemibold`, `.primary`. Shows "Me" for sent messages |
| Snippet | `message.snippet` (Gmail API plain text), `Typography.callout`, `.secondary`, `.lineLimit(1)` |
| Timestamp | `date.formattedRelative`, `Typography.captionRegular`, `.tertiary` |
| Sent-by-me | 2pt accent-colored leading border via `.overlay(Rectangle().frame(width: 2).foregroundStyle(.accent), alignment: .leading)` |
| Hover | `.quaternary` fill background |
| Separator | 1pt `Color(.separatorColor)` bottom border on each card except the last |
| Attachments | Paperclip icon (`Typography.captionSmall`, `.tertiary`) before timestamp if message has attachments |
| Unread | 6pt blue dot on leading edge (before avatar) + semibold sender name |

### Expanded State

```
┌─────────────────────────────────────────────────────────────────┐
│  [Avatar 24]  Sender Name                          2:30 PM     │
│               sender@email.com -> me, Bob, +2                  │
├ - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -┤
│                                                                 │
│  [Full HTML email body via HTMLEmailView]                        │
│                                                                 │
│  [Show quoted text]  (capsule button, if applicable)            │
│                                                                 │
│  Attachments section (if any)                                   │
│  [attachment-chip] [attachment-chip]                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

| Element | Spec |
|---------|------|
| Header row | Same as collapsed |
| Recipients line | `Typography.captionRegular`, `.tertiary`. Format: "sender@email.com -> me" / "-> me, John, +3" |
| Separator | `Color(.separatorColor).opacity(0.5)`, `Spacing.sm` padding above/below |
| HTML body | `HTMLEmailView` — only instantiated when expanded |
| Quote stripping | Reuses `GmailThreadMessageView.stripQuotedHTML()` |
| Show/hide quoted | Existing capsule button design (`.quaternary` fill, chevron + text) |
| Attachments | Existing `AttachmentChipView`, shown per-message |
| Sent-by-me | Same 2pt accent leading border, extends full card height |
| Padding | `Spacing.md` (12pt) horizontal, `Spacing.sm` (8pt) vertical for header, `Spacing.md` for body |

## Expand/Collapse Behavior

### State

```swift
@State private var expandedMessageIDs: Set<String>
```

Initialized with the latest message ID on thread load.

### Interaction

- Tap on **header row** toggles expand/collapse
- Tap inside **body content** (HTML, attachments) does NOT toggle — it's content interaction
- Header row uses `.contentShape(Rectangle())` for reliable hit target

### Animation

- Toggle wrapped in `withAnimation(SerifAnimation.springSnappy)` (0.3s response, 0.8 damping)
- Content clips with `.clipped()` during animation
- Expanded card body fades in with 0.15s opacity transition after card finishes expanding (hides WKWebView height measurement delay)
- Collapse is instant clip (no fade-out — feels snappier)

### Collapse All

- Appears in conversation header row: "N messages" label left, "Collapse All" button right
- Only visible when 2+ cards are expanded
- Resets `expandedMessageIDs` to `{latestMessageID}`
- Animated with `SerifAnimation.springSnappy`

### Auto-scroll

- `ScrollViewReader` scrolls to latest message ID with `.bottom` anchor
- Delayed slightly (`DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)`) to let layout settle

## Data Flow & ViewModel Changes

### EmailDetailViewModel

- **Add:** `allMessagesChronological: [GmailMessage]` — all messages sorted by `internalDate` ascending
- **Remove:** `olderThreadMessages` computed property (no longer needed)
- **Keep:** `resolvedMessageHTML: [String: String]` — already keyed by message ID, works as-is
- **Keep:** `latestMessage` — still needed for thread metadata (subject, labels, etc.)
- **Keep:** Inline image resolution — already per-message via `resolveInlineImagesForOlderMessages`

### ThreadMessageCardView inputs

```swift
struct ThreadMessageCardView: View {
    let message: GmailMessage
    @Binding var isExpanded: Bool
    let fromAddress: String
    var resolvedHTML: String?
    var onOpenLink: ((URL) -> Void)?
    var attachmentPairs: [(Attachment, GmailMessagePart?)]
    var onPreviewAttachment: ((Attachment, GmailMessagePart) -> Void)?
    var onDownloadAttachment: ((Attachment, GmailMessagePart) -> Void)?
}
```

## Files Changed

| File | Action | Summary |
|------|--------|---------|
| `Views/EmailDetail/ThreadMessageCardView.swift` | Create | New collapsible card component |
| `Views/EmailDetail/EmailDetailView.swift` | Modify | Replace hero+bubbles with unified card list, add `expandedMessageIDs`, add conversation header with Collapse All |
| `ViewModels/EmailDetailViewModel.swift` | Modify | Add `allMessagesChronological`, remove `olderThreadMessages` |
| `Views/EmailDetail/GmailThreadMessageView.swift` | Modify | Remove `ChatBubbleShape` and the view body; keep `stripQuotedHTML` as static utility |

### Not changed

`HTMLEmailView`, `AttachmentChipView`, `ReplyBarView`, `DetailPaneView`, `SmartReplyChipsView`, `DesignTokens.swift`, models, services.

## Performance

| Aspect | Before | After |
|--------|--------|-------|
| WKWebView instances | 1 (latest) + N (all older messages) | 1 (latest) + only expanded cards |
| Collapsed card cost | N/A (all fully rendered) | ~48pt SwiftUI row with text — negligible |
| Memory for 20-message thread | 20 WKWebViews | 1 WKWebView (default) |
| Scroll performance | Heavy (all WebViews in LazyVStack) | Light (mostly native SwiftUI rows) |

## Out of Scope

- Keyboard navigation (arrow keys between cards, Space to toggle) — future enhancement
- Drag-to-reorder or grouping cards
- Inline reply from within a card (reply bar at bottom handles this)
- Sticky thread header (considered, rejected for complexity)
- Search within thread
