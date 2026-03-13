# Collapsible Conversation Cards — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the chat-bubble thread display with collapsible conversation cards — each email in a thread is a card, the latest is expanded, older ones are collapsed.

**Architecture:** Unified `ThreadMessageCardView` component replaces both the hero latest-message section and `GmailThreadMessageView` chat bubbles. Parent `EmailDetailView` manages expansion state via `Set<String>`. ViewModel removes the latest/older split and unifies inline image resolution into a single dictionary.

**Tech Stack:** Swift 6.2, SwiftUI, macOS 26+, WKWebView (HTMLEmailView), GRDB

**Spec:** `docs/superpowers/specs/2026-03-14-collapsible-conversation-cards-design.md`

**Tooling:** Use Serena symbolic tools (`find_symbol`, `replace_symbol_body`, `get_symbols_overview`) for code navigation and editing of whole symbols. Use `Edit` for targeted few-line changes. Read Serena `code_style` memory before writing Swift code. Use `serena-routing` skill in subagents.

---

## Chunk 1: ViewModel Changes

### Task 1: Unify inline image resolution — remove `resolvedHTML` property

The ViewModel currently has two separate inline-image stores: `resolvedHTML: String?` for the latest message and `resolvedMessageHTML: [String: String]` for older messages. Unify them so all messages use the per-message dictionary.

**Files:**
- Modify: `Serif/ViewModels/EmailDetailViewModel.swift`

- [ ] **Step 1: Remove `resolvedHTML` property and update `resolveInlineImages`**

In `EmailDetailViewModel.swift`, apply these changes **atomically** (all in one edit pass to avoid intermediate compile failures):

1. Add a new computed property for tracker-sanitized HTML (replaces `displayHTML`) — add this near the existing `displayHTML`:

```swift
/// Tracker-sanitized HTML for the latest message, or nil if no tracker analysis ran.
var trackerSanitizedHTML: String? {
    guard let result = trackerResult else { return nil }
    return allowTrackers ? result.originalHTML : result.sanitizedHTML
}
```

2. Modify `resolveInlineImages(for:)` (line 199) to write to `resolvedMessageHTML[message.id]` instead of `resolvedHTML`:

```swift
private func resolveInlineImages(for message: GmailMessage) async {
    guard !message.inlineParts.isEmpty else { return }

    let baseHTML = trackerSanitizedHTML ?? message.htmlBody ?? ""
    guard !baseHTML.isEmpty else { return }

    resolvedMessageHTML[message.id] = await Self.replaceCIDReferences(in: baseHTML, message: message, accountID: accountID)
}
```

3. In `loadThread(id:)`, remove the line `resolvedHTML = nil` (line 52). Add `resolvedMessageHTML.removeAll()` in its place.

4. **After** the above changes compile cleanly with the shim, delete `var resolvedHTML: String?` (line 13) and `var displayHTML: String?` (lines 20-23), then add compatibility shims (see Step 2).

- [ ] **Step 2: Build and verify no compile errors**

Run: `cd /Users/votan/coding/gmail && xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -20`

If there are compile errors referencing `resolvedHTML` or `displayHTML` in `EmailDetailView.swift`, note them — they will be fixed in Task 4 when we rewrite the view. For now, temporarily add a compatibility shim:

```swift
/// Compatibility shim — will be removed in Task 4.
var resolvedHTML: String? { latestMessage.flatMap { resolvedMessageHTML[$0.id] } }
var displayHTML: String? { trackerSanitizedHTML }
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```
git add Serif/ViewModels/EmailDetailViewModel.swift
git commit -m "refactor: unify resolvedHTML into per-message resolvedMessageHTML dict"
```

### Task 2: Add `allMessagesChronological` and update attachment methods

**Files:**
- Modify: `Serif/ViewModels/EmailDetailViewModel.swift`

- [ ] **Step 1: Add `allMessagesChronological` computed property**

Add after the existing `messages` property (line 461):

```swift
/// All thread messages in chronological order (oldest first).
/// Uses Gmail API's native array order — already sorted by internalDate ascending.
var allMessagesChronological: [GmailMessage] { messages }
```

- [ ] **Step 2: Update `loadAndPreview` to accept messageID parameter**

Replace the `loadAndPreview` method (lines 435-444) — remove the `latestMessage?.id` hardcoding:

```swift
func loadAndPreview(
    attachment: Attachment,
    part: GmailMessagePart,
    messageID: String,
    onPreviewAttachment: ((Data?, String, Attachment.FileType) -> Void)?
) async {
    onPreviewAttachment?(nil, attachment.name, attachment.fileType)
    guard let data = try? await downloadAttachment(messageID: messageID, part: part) else { return }
    onPreviewAttachment?(data, attachment.name, attachment.fileType)
}
```

- [ ] **Step 3: Update `downloadAndSave` to accept messageID parameter**

Replace the `downloadAndSave` method (lines 446-457):

```swift
func downloadAndSave(
    attachment: Attachment,
    part: GmailMessagePart,
    messageID: String
) async -> Data? {
    do {
        return try await downloadAttachment(messageID: messageID, part: part)
    } catch {
        ToastManager.shared.show(message: "Download failed: \(error.localizedDescription)", type: .error)
        return nil
    }
}
```

- [ ] **Step 4: Add per-message attachment pairs helper**

Add a new method for computing attachment pairs for any message:

```swift
/// Attachment + part tuples for a specific message.
func attachmentPairsForMessage(_ message: GmailMessage) -> [(Attachment, GmailMessagePart?)] {
    message.attachmentParts.map { part in
        (GmailDataTransformer.makeAttachment(from: part, messageId: message.id), part)
    }
}
```

- [ ] **Step 5: Build and verify**

Run: `cd /Users/votan/coding/gmail && xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -20`

If `EmailDetailView.swift` has compile errors from the changed `loadAndPreview`/`downloadAndSave` signatures, add temporary compatibility overloads:

```swift
/// Compatibility shim — will be removed in Task 4.
func loadAndPreview(attachment: Attachment, part: GmailMessagePart, onPreviewAttachment: ((Data?, String, Attachment.FileType) -> Void)?) async {
    guard let msgID = latestMessage?.id else { return }
    await loadAndPreview(attachment: attachment, part: part, messageID: msgID, onPreviewAttachment: onPreviewAttachment)
}
func downloadAndSave(attachment: Attachment, part: GmailMessagePart) async -> Data? {
    guard let msgID = latestMessage?.id else { return nil }
    return await downloadAndSave(attachment: attachment, part: part, messageID: msgID)
}
```

Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```
git add Serif/ViewModels/EmailDetailViewModel.swift
git commit -m "feat: add allMessagesChronological, per-message attachment methods"
```

---

## Chunk 2: ThreadMessageCardView — New Component

### Task 3: Create `ThreadMessageCardView`

The core new component. A collapsible card that shows a compact header when collapsed, and expands to show full HTML email body, quote controls, and attachments.

**Files:**
- Create: `Serif/Views/EmailDetail/ThreadMessageCardView.swift`

- [ ] **Step 1: Make `computeFullHTML` accessible from `GmailThreadMessageView`**

In `Serif/Views/EmailDetail/GmailThreadMessageView.swift`, change `computeFullHTML` from `private static` to `static` (remove the `private` keyword, line 37). This must be done BEFORE creating the new file, as `ThreadMessageCardView` calls this method.

- [ ] **Step 2: Create the file with the full implementation**

Create `Serif/Views/EmailDetail/ThreadMessageCardView.swift`:

```swift
import SwiftUI

struct ThreadMessageCardView: View {
    let message: GmailMessage
    let email: Email
    let isExpanded: Bool
    let fromAddress: String
    let isLast: Bool
    var resolvedHTML: String?
    var onToggle: () -> Void
    var onOpenLink: ((URL) -> Void)?
    var attachmentPairs: [(Attachment, GmailMessagePart?)] = []
    var onPreviewAttachment: ((Attachment, GmailMessagePart) -> Void)?
    var onDownloadAttachment: ((Attachment, GmailMessagePart) -> Void)?

    @State private var showQuoted = false
    @State private var contentHeight: CGFloat = 60
    @State private var showSenderInfo = false
    @State private var isHovering = false

    /// Cached sender contact — parsed once at init.
    private let sender: Contact
    /// Cached sent-by-me flag.
    private let isSentByMe: Bool
    /// Cached full HTML.
    private let cachedFullHTML: String
    /// Cached quote-stripped parts.
    private let cachedHTMLParts: (original: String, quoted: String?)

    init(
        message: GmailMessage,
        email: Email,
        isExpanded: Bool,
        fromAddress: String,
        isLast: Bool = false,
        resolvedHTML: String? = nil,
        onToggle: @escaping () -> Void,
        onOpenLink: ((URL) -> Void)? = nil,
        attachmentPairs: [(Attachment, GmailMessagePart?)] = [],
        onPreviewAttachment: ((Attachment, GmailMessagePart) -> Void)? = nil,
        onDownloadAttachment: ((Attachment, GmailMessagePart) -> Void)? = nil
    ) {
        self.message = message
        self.email = email
        self.isExpanded = isExpanded
        self.fromAddress = fromAddress
        self.isLast = isLast
        self.resolvedHTML = resolvedHTML
        self.onToggle = onToggle
        self.onOpenLink = onOpenLink
        self.attachmentPairs = attachmentPairs
        self.onPreviewAttachment = onPreviewAttachment
        self.onDownloadAttachment = onDownloadAttachment

        let parsedSender = GmailDataTransformer.parseContact(message.from)
        self.sender = parsedSender
        self.isSentByMe = !fromAddress.isEmpty && parsedSender.email.lowercased() == fromAddress.lowercased()

        let html = GmailThreadMessageView.computeFullHTML(message: message, resolvedHTML: resolvedHTML)
        self.cachedFullHTML = html
        self.cachedHTMLParts = GmailThreadMessageView.stripQuotedHTML(html)
    }

    // MARK: - Snippet text

    private var snippetText: String {
        if let snippet = message.snippet, !snippet.isEmpty { return snippet }
        if let plain = message.plainBody { return String(plain.prefix(100)) }
        return ""
    }

    // MARK: - Recipients line

    private var recipientsLine: String {
        let to = message.to
        let parts = to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let displayParts = parts.prefix(2).map { part in
            if part.lowercased() == fromAddress.lowercased() { return "me" }
            // Extract just the name or email before <
            if let angleBracket = part.firstIndex(of: "<") {
                return String(part[part.startIndex..<angleBracket]).trimmingCharacters(in: .whitespaces)
            }
            return part
        }
        let remaining = parts.count - 2
        var result = "\(sender.email) \u{2192} \(displayParts.joined(separator: ", "))"
        if remaining > 0 { result += ", +\(remaining)" }
        return result
    }

    // MARK: - Rendered HTML

    private var renderedHTML: String {
        if showQuoted || cachedHTMLParts.quoted == nil {
            return cachedFullHTML
        }
        return cachedHTMLParts.original
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row — always visible, tappable to toggle
            headerRow
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }
                .onHover { isHovering = $0 }

            // Expanded content — two-phase animation:
            // Spring for card height, easeIn fade for body (hides WKWebView height measurement)
            if isExpanded {
                expandedContent
                    .clipped()
                    .opacity(isExpanded ? 1 : 0)
                    .animation(.easeIn(duration: 0.15), value: isExpanded)
                    .transaction { t in
                        if !isExpanded { t.animation = nil } // instant collapse
                    }
            }

            // Bottom separator (except last card)
            if !isLast {
                Divider()
                    .background(Color(.separatorColor))
            }
        }
        .background(isHovering && !isExpanded ? Color(.quaternaryLabelColor) : Color.clear)
        .overlay(alignment: .leading) {
            if isSentByMe {
                Rectangle()
                    .frame(width: 2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .animation(SerifAnimation.springSnappy, value: isExpanded)
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: 8) {
            // Unread indicator
            if message.isUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }

            AvatarView(
                initials: sender.initials,
                color: sender.avatarColor,
                size: 24,
                avatarURL: sender.avatarURL,
                senderDomain: sender.domain
            )

            VStack(alignment: .leading, spacing: isExpanded ? 2 : 0) {
                HStack {
                    Text(isSentByMe ? "Me" : sender.name)
                        .font(message.isUnread ? Typography.calloutSemibold : Typography.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !isExpanded {
                        Text(snippetText)
                            .font(Typography.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }

                    Spacer(minLength: 4)

                    if !isExpanded && message.hasPartsWithFilenames {
                        Image(systemName: "paperclip")
                            .font(Typography.captionSmall)
                            .foregroundStyle(.tertiary)
                    }

                    if let date = message.date {
                        Text(date.formattedRelative)
                            .font(Typography.captionRegular)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Recipients line (expanded only)
                if isExpanded {
                    Text(recipientsLine)
                        .font(Typography.captionRegular)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .onHover { showSenderInfo = $0 }
                        .popover(isPresented: $showSenderInfo, arrowEdge: .bottom) {
                            SenderInfoPopover(message: message, email: email)
                        }
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .background(Color(.separatorColor).opacity(0.5))
                .padding(.horizontal, Spacing.md)

            HTMLEmailView(html: renderedHTML, contentHeight: $contentHeight, onOpenLink: onOpenLink)
                .frame(height: contentHeight)
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.sm)
                .padding(.bottom, cachedHTMLParts.quoted != nil ? Spacing.xs : Spacing.md)

            if cachedHTMLParts.quoted != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showQuoted.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showQuoted ? "chevron.up" : "chevron.down")
                            .font(Typography.captionSmallMedium)
                        Text(showQuoted ? "Hide quoted" : "Show quoted")
                            .font(Typography.captionSmallMedium)
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.md)
            }

            if !attachmentPairs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(Typography.subheadRegular)
                        Text("\(attachmentPairs.count) Attachment\(attachmentPairs.count > 1 ? "s" : "")")
                            .font(Typography.subhead)
                    }
                    .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach(attachmentPairs, id: \.0.id) { (attachment, part) in
                            AttachmentChipView(
                                attachment: attachment,
                                onPreview: part.map { p in { onPreviewAttachment?(attachment, p) } },
                                onDownload: part.map { p in { onDownloadAttachment?(attachment, p) } }
                            )
                        }
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.md)
            }
        }
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/votan/coding/gmail && xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -20`

Expected: BUILD SUCCEEDED (the new file compiles; it's not wired into the view hierarchy yet)

- [ ] **Step 4: Commit**

```
git add Serif/Views/EmailDetail/ThreadMessageCardView.swift Serif/Views/EmailDetail/GmailThreadMessageView.swift
git commit -m "feat: add ThreadMessageCardView — collapsible conversation card component"
```

---

## Chunk 3: Rewire EmailDetailView

### Task 4: Rewrite EmailDetailView to use conversation cards

Replace the hero + chat bubble layout with the unified card list.

**Files:**
- Modify: `Serif/Views/EmailDetail/EmailDetailView.swift`

- [ ] **Step 1: Update state variables**

In `EmailDetailView`:

1. **Remove** these state variables:
   - `@State private var emailBodyHeight: CGFloat = 100` (line 13)
   - `@State private var showSenderInfo = false` (line 15)
   - `@State private var showQuotedMain = false` (line 17)
   - `@State private var cachedMainHTMLParts: (original: String, quoted: String?)?` (line 18)
   - `@State private var cachedMainHTMLSource: String?` (line 19)
   - `@ScaledMetric(relativeTo: .body) private var senderAvatarSize: CGFloat = 40` (line 22)

2. **Add** new state:
   ```swift
   @State private var expandedMessageIDs: Set<String> = []
   ```

3. **Remove** the `olderThreadMessages` computed property (lines 74-76).

4. **Remove** the `mainHTMLParts(for:)` method (lines 323-331).

5. **Remove** the `senderHeader` computed property (lines 374-409).

- [ ] **Step 2: Rewrite the body**

Replace the `body` property with the new layout. The key structural change: wrap in `ScrollViewReader`, replace the hero section + `conversationSection` with a unified `conversationCards` section.

```swift
var body: some View {
    VStack(spacing: 0) {
        if detailVM.isLoading && detailVM.thread == nil {
            EmailDetailSkeletonView()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Thread metadata
                        threadMetadata

                        // Conversation cards
                        conversationCards
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                }
                .task(id: detailVM.latestMessage?.id) {
                    if let latestID = detailVM.latestMessage?.id {
                        expandedMessageIDs = [latestID]
                        try? await Task.sleep(for: .milliseconds(100))
                        withAnimation { proxy.scrollTo(latestID, anchor: .bottom) }
                    }
                }
                .contentTransition(.opacity)
                .animation(SerifAnimation.springSnappy, value: email.id)
                .safeAreaInset(edge: .bottom) {
                    ReplyBarView(
                        email: email,
                        accountID: accountID,
                        fromAddress: fromAddress,
                        mailStore: mailStore,
                        onOpenLink: actions.onOpenLink,
                        onGenerateQuickReplies: { [detailVM] email in
                            await detailVM.generateQuickReplies(for: email)
                        },
                        onLoadDraft: actions.onLoadDraft,
                        smartReplySuggestions: detailVM.smartReplySuggestions
                    )
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.lg)
                    .task(id: email.id) {
                        detailVM.loadSmartReplies(for: email)
                    }
                }
            }
        }
    }
    .task(id: email.id) {
        await loadThread()
    }
}
```

- [ ] **Step 3: Add `threadMetadata` extracted view**

Extract the unchanged thread-level metadata into its own computed property:

```swift
private var threadMetadata: some View {
    VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top) {
            Text(detailVM.latestMessage?.subject ?? email.subject)
                .font(Typography.title)
                .foregroundStyle(.primary)

            Spacer()

            Menu {
                if isMailingList, let url = resolvedUnsubscribeURL, !alreadyUnsubscribed {
                    Button(role: .destructive) {
                        Task {
                            let msgID = email.gmailMessageID
                            let success = await actions.onUnsubscribe?(url, oneClick, msgID) ?? false
                            if success { didUnsubscribe = true }
                        }
                    } label: {
                        Label("Unsubscribe", systemImage: "xmark.circle")
                    }
                    Divider()
                }
                Button {
                    guard let msg = detailVM.latestMessage else { return }
                    actions.onDownloadMessage?(msg, detailVM.accountID)
                } label: {
                    Label("Download Message", systemImage: "arrow.down.circle")
                }
                Button {
                    guard let msg = detailVM.latestMessage else { return }
                    actions.onShowOriginal?(msg, detailVM.accountID)
                } label: {
                    Label("Show Original", systemImage: "doc.text")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(Typography.body)
                    .foregroundStyle(.tertiary)
                    .frame(width: ButtonSize.lg, height: ButtonSize.lg)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Message options")
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.sm)

        HStack(spacing: 6) {
            LabelEditorView(
                currentLabelIDs: currentLabelIDs,
                allLabels: allLabels,
                detailVM: detailVM,
                onAddLabel: actions.onAddLabel,
                onRemoveLabel: actions.onRemoveLabel,
                onCreateAndAddLabel: actions.onCreateAndAddLabel
            )
            .zIndex(1)

            if !labelSuggestions.isEmpty {
                ForEach(labelSuggestions, id: \.name) { suggestion in
                    Button {
                        applyLabelSuggestion(suggestion)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: suggestion.isNew ? "plus.circle" : "plus")
                                .font(Typography.captionSmall)
                            Text(suggestion.name)
                                .font(Typography.captionSmallRegular)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.08))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                .animation(SerifAnimation.springSnappy, value: labelSuggestions.map(\.name))
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.md)

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            InsightCardView(email: email)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
        }
        #endif

        if detailVM.hasBlockedTrackers {
            TrackerBannerView(
                trackerCount: detailVM.blockedTrackerCount,
                trackers: detailVM.trackerResult?.trackers ?? [],
                onAllow: { detailVM.allowBlockedContent() }
            )
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.md)
        }

        if let invite = detailVM.calendarInvite {
            CalendarInviteCardView(
                invite: invite,
                isLoading: detailVM.rsvpInProgress,
                showOriginalEmail: $showOriginalInviteEmail,
                onAccept:  { Task { await detailVM.sendRSVP(.accepted) } },
                onDecline: { Task { await detailVM.sendRSVP(.declined) } },
                onMaybe:   { Task { await detailVM.sendRSVP(.maybe) } }
            )
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.md)
        }
    }
    .task(id: email.id) {
        labelSuggestions = []
        guard aiLabelSuggestionsEnabled else { return }
        let suggestions = await detailVM.generateLabelSuggestions(
            for: email,
            existingLabels: allLabels
        )
        withAnimation { labelSuggestions = suggestions }
    }
}
```

- [ ] **Step 4: Add `conversationCards` computed property**

This is the new unified card list replacing both the hero section and `conversationSection`:

```swift
private var conversationCards: some View {
    VStack(alignment: .leading, spacing: 0) {
        // Conversation header
        let allMessages = detailVM.allMessagesChronological
        if allMessages.count > 1 {
            HStack {
                Text("\(allMessages.count) messages")
                    .font(Typography.captionRegular)
                    .foregroundStyle(.tertiary)

                Spacer()

                if expandedMessageIDs.count > 1 {
                    Button {
                        withAnimation(SerifAnimation.springSnappy) {
                            if let latestID = detailVM.latestMessage?.id {
                                expandedMessageIDs = [latestID]
                            }
                        }
                    } label: {
                        Text("Collapse Others")
                            .font(Typography.captionRegular)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.sm)
        }

        // Card list
        LazyVStack(spacing: 1) {
            ForEach(Array(allMessages.enumerated()), id: \.element.id) { index, message in
                let isLastCard = index == allMessages.count - 1
                ThreadMessageCardView(
                    message: message,
                    email: email,
                    isExpanded: expandedMessageIDs.contains(message.id),
                    fromAddress: fromAddress,
                    isLast: isLastCard,
                    resolvedHTML: detailVM.resolvedMessageHTML[message.id],
                    onToggle: {
                        withAnimation(SerifAnimation.springSnappy) {
                            if expandedMessageIDs.contains(message.id) {
                                expandedMessageIDs.remove(message.id)
                            } else {
                                expandedMessageIDs.insert(message.id)
                            }
                        }
                    },
                    onOpenLink: actions.onOpenLink,
                    attachmentPairs: detailVM.attachmentPairsForMessage(message),
                    onPreviewAttachment: { attachment, part in
                        Task {
                            await detailVM.loadAndPreview(
                                attachment: attachment,
                                part: part,
                                messageID: message.id,
                                onPreviewAttachment: actions.onPreviewAttachment
                            )
                        }
                    },
                    onDownloadAttachment: { attachment, part in
                        Task {
                            guard let data = await detailVM.downloadAndSave(
                                attachment: attachment,
                                part: part,
                                messageID: message.id
                            ) else { return }
                            saveAttachmentData(data, named: attachment.name)
                        }
                    }
                )
                .id(message.id)
            }
        }
        .padding(.horizontal, Spacing.xl)
    }
}
```

**Note:** The old layout gated the latest message's HTML body behind `if detailVM.calendarInvite == nil || showOriginalInviteEmail`. In the new card design, every card's expanded state shows its HTML body independently — the `CalendarInviteCardView` (in thread metadata) still has its own `showOriginalEmail` toggle, but it no longer gates the message card content. This is intentional: the calendar invite card is a summary widget, and the full message is always accessible via its card.

- [ ] **Step 5: Remove the old `conversationSection` and `attachmentsSection`**

Delete the `conversationSection` computed property (lines 442-458) and the `attachmentsSection` computed property (lines 417-438), since attachments are now per-card inside `ThreadMessageCardView`.

Also delete the `displayAttachments` computed property (lines 70-72) and the `attachmentPairs` computed property (lines 413-415) — these are replaced by per-message `attachmentPairsForMessage`.

- [ ] **Step 6: Remove compatibility shims from ViewModel**

Go back to `EmailDetailViewModel.swift` and remove any compatibility shims added in Tasks 1-2 (the `resolvedHTML` and `displayHTML` computed properties, and the old-signature `loadAndPreview`/`downloadAndSave` methods).

- [ ] **Step 7: Build and fix compile errors iteratively**

Run: `cd /Users/votan/coding/gmail && xcodebuild -scheme Serif -configuration Debug build 2>&1 | grep "error:" | head -20`

Fix any remaining compile errors. Common issues:
- Missing references to removed properties
- Signature mismatches on `loadAndPreview`/`downloadAndSave`

Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```
git add Serif/Views/EmailDetail/EmailDetailView.swift Serif/ViewModels/EmailDetailViewModel.swift
git commit -m "feat: replace hero + chat bubbles with unified collapsible conversation cards"
```

---

## Chunk 4: Clean Up Old Code

### Task 5: Clean up GmailThreadMessageView

Remove the chat bubble view and shape, keeping only the static `stripQuotedHTML` utility.

**Files:**
- Modify: `Serif/Views/EmailDetail/GmailThreadMessageView.swift`

- [ ] **Step 1: Strip GmailThreadMessageView to utility-only**

Remove the entire `body`, all `@State` properties, `renderedHTML`, `sender`/`isSentByMe` cached properties, and the `init`. Keep only:
- `static func computeFullHTML(message:resolvedHTML:) -> String`
- `static func stripQuotedHTML(_ html:) -> (original: String, quoted: String?)`

Consider renaming the file/struct to `HTMLQuoteStripper` or keeping the name for git history continuity. Keeping the name is simpler.

The resulting file should be approximately:

```swift
import SwiftUI

/// Utility for HTML quote stripping and full-HTML computation.
/// View rendering has moved to ThreadMessageCardView.
enum GmailThreadMessageView {
    /// Compute the full HTML from message parts.
    static func computeFullHTML(message: GmailMessage, resolvedHTML: String?) -> String {
        if let resolved = resolvedHTML, !resolved.isEmpty { return resolved }
        if let html = message.htmlBody, !html.isEmpty { return html }
        if let plain = message.plainBody, !plain.isEmpty { return "<p>\(plain)</p>" }
        let body = message.body
        return body.isEmpty ? "" : "<p>\(body)</p>"
    }

    /// Removes quoted/replied content from HTML, returning (original, quoted?).
    static func stripQuotedHTML(_ html: String) -> (original: String, quoted: String?) {
        // ... (keep entire existing implementation unchanged)
    }
}
```

Note: Changed from `struct` to `enum` since it has no instances.

- [ ] **Step 2: Remove ChatBubbleShape**

Delete the `private struct ChatBubbleShape: Shape` at the bottom of the file (lines 209-251). It's no longer referenced anywhere.

- [ ] **Step 3: Verify no other files reference the removed view**

Run: `grep -rn "GmailThreadMessageView(" Serif/ --include="*.swift"` — should only find `ThreadMessageCardView.swift` calling the static methods.

Run: `grep -rn "ChatBubbleShape" Serif/ --include="*.swift"` — should return nothing.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/votan/coding/gmail && xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```
git add Serif/Views/EmailDetail/GmailThreadMessageView.swift
git commit -m "refactor: strip GmailThreadMessageView to utility-only, remove ChatBubbleShape"
```

### Task 6: Remove `olderThreadMessages` from ViewModel

**Files:**
- Modify: `Serif/ViewModels/EmailDetailViewModel.swift`

- [ ] **Step 1: Remove `olderThreadMessages` computed property**

Delete the `olderThreadMessages` computed property (around line 331-334) if it wasn't already removed in Task 4.

- [ ] **Step 2: Remove old `attachmentPairs(fallback:)` and `displayAttachments(fallback:)` methods**

These are replaced by `attachmentPairsForMessage(_:)`. Delete them if not already removed.

- [ ] **Step 3: Verify no references remain**

Run: `grep -rn "olderThreadMessages\|displayAttachments\|attachmentPairs(fallback" Serif/ --include="*.swift"`
Expected: No matches.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/votan/coding/gmail && xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```
git add Serif/ViewModels/EmailDetailViewModel.swift
git commit -m "chore: remove obsolete olderThreadMessages and attachment helpers"
```

---

## Chunk 5: Final Verification

### Task 7: Full build + visual verification

- [ ] **Step 1: Clean build**

Run: `cd /Users/votan/coding/gmail && xcodebuild -scheme Serif -configuration Debug clean build 2>&1 | tail -30`
Expected: BUILD SUCCEEDED with no warnings related to our changes.

- [ ] **Step 2: Verify no dead code**

Run these grep checks:
```
grep -rn "showQuotedMain\|cachedMainHTML\|senderAvatarSize\|emailBodyHeight" Serif/ --include="*.swift"
grep -rn "ChatBubbleShape\|chatBubble\|isSentByMe.*Spacer" Serif/ --include="*.swift"
```
Expected: No matches (except `isSentByMe` in `ThreadMessageCardView` which is valid).

- [ ] **Step 3: Verify the old `resolvedHTML` shim is fully removed**

Run: `grep -rn "var resolvedHTML:" Serif/ViewModels/ --include="*.swift"`
Expected: No matches (only `resolvedMessageHTML` should exist).

- [ ] **Step 4: Commit final state**

If any cleanup was needed:
```
git add -A && git commit -m "chore: final cleanup after conversation cards migration"
```

- [ ] **Step 5: Run the app and visually verify**

Open in Xcode, build and run. Check:
1. Single-message threads show one expanded card (no conversation header)
2. Multi-message threads show collapsed cards with the latest expanded at the bottom
3. Clicking a collapsed card expands it with spring animation
4. Clicking an expanded card's header collapses it
5. "Collapse Others" appears when 2+ cards are expanded and works correctly
6. Attachments appear per-message inside expanded cards
7. Quote stripping works (show/hide quoted text button)
8. Sent-by-me messages show accent-colored left border
9. Hover state on collapsed cards shows subtle highlight
10. Scroll auto-positions to the latest message on thread load
