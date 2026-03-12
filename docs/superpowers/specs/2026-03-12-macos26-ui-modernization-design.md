# macOS 26 UI/UX Modernization — Design Spec

## Overview

Modernize Serif's UI to fully adopt Apple's macOS 26 (Tahoe) design system — Liquid Glass, `NavigationSplitView`, system toolbar patterns, semantic typography, native components, and accessibility. The goal is to look and feel like a first-party Apple app.

## Scope

10 changes organized in 3 layers (built in dependency order):

### Layer 1: Foundation (everything else builds on this)

1. **NavigationSplitView migration** — replaces the manual `HStack(spacing: 0)` three-column layout
2. **Toolbar migration** — moves email actions to the window toolbar with HIG-correct placements

### Layer 2: Components (independent of each other, depend on Layer 1)

3. **Settings scene** — replaces SlidePanel settings with a proper `Settings` scene
4. **Accessibility** — adds labels, hints, traits, and element grouping throughout
5. **Semantic typography** — replaces all hardcoded `.system(size:)` with semantic text styles
6. **SwipeActions** — replaces custom NSEvent-based swipe with `.swipeActions()`
7. **Menu icons** — adds SF Symbols to all `SerifCommands` menu items

### Layer 3: New Capabilities (independent, depend on Layer 1)

8. **Native WebView** — replaces `WKWebView` wrapper with SwiftUI `WebView`
9. **Spotlight & Handoff** — adds `NSUserActivity` and Core Spotlight indexing
10. **Focus management** — adds `@FocusState` pane navigation

---

## 1. NavigationSplitView Migration

### Current State

`ContentView.mainLayout` is:
```
ZStack {
    HStack(spacing: 0) {
        SidebarView(...)           // 60pt collapsed, 200pt expanded
        ListPaneView(...)          // min:280, ideal:320, max:380
        DetailPaneView(...)        // min:400, clipped RoundedRect
    }
    // overlays: keyboard shortcuts, toasts, slide panels
}
```

`SidebarView` manually animates between collapsed (60pt, icon-only) and expanded (200pt) states with `.regularMaterial` in a `RoundedRectangle(cornerRadius: 12)`.

### Target State

```swift
NavigationSplitView(columnVisibility: $columnVisibility) {
    SidebarContent(...)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
} content: {
    ListContent(...)
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
} detail: {
    DetailContent(...)
}
```

### Changes

**SerifApp.swift:**
- Remove `.windowStyle(.titleBar)` and `.windowToolbarStyle(.unifiedCompact)` — let NavigationSplitView manage chrome
- Keep default window size (1200x750) and minimum (900x600)

**ContentView.swift:**
- Replace `HStack(spacing: 0)` with `NavigationSplitView(columnVisibility:)`
- Replace `@State private var sidebarExpanded: Bool` (via coordinator) with `@State private var columnVisibility: NavigationSplitViewVisibility = .all`
- Sidebar toggle uses `columnVisibility` instead of custom animation
- Overlays (toasts, panels) remain in a ZStack wrapping the NavigationSplitView
- Attachments mode: when `selectedFolder == .attachments`, the content+detail columns show `AttachmentExplorerView`

**SidebarView.swift:**
- Remove all manual width/collapse logic (sidebarWidth, isExpanded animation, collapsed-vs-expanded branching)
- Remove `.regularMaterial` background and `RoundedRectangle` clipping — system provides Liquid Glass floating sidebar
- Remove 52pt spacer for traffic lights — NavigationSplitView handles safe area
- Content becomes a simple `List(selection:)` with sections for folders, inbox categories, and labels
- Use `List` with `.listStyle(.sidebar)` for proper system selection highlighting and disclosure groups
- Bottom buttons (Settings, Help, Debug) move to a `.safeAreaInset(edge: .bottom)` or toolbar

**ListPaneView.swift:**
- Remove `.frame(minWidth:idealWidth:maxWidth:)` — NavigationSplitView manages column width
- Column width set via `.navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)` on the content column

**DetailPaneView.swift:**
- Remove `.frame(minWidth: 400)` — NavigationSplitView manages width
- Remove `.clipShape(RoundedRectangle(cornerRadius: 12))` and padding — system handles chrome
- Remove `.padding(.vertical, 8).padding(.trailing, 8)` — no manual edge spacing

**AppCoordinator.swift:**
- Remove `sidebarExpanded` property if it exists (column visibility is now local SwiftUI state)
- All other navigation state unchanged

### Sidebar List Conversion

The sidebar currently uses `ScrollView` with manually positioned views. Convert to:

```swift
List(selection: $selectedFolder) {
    Section("Mailbox") {
        ForEach(Folder.mainCases) { folder in
            Label(folder.name, systemImage: folder.icon)
                .badge(unreadCount(for: folder))
        }
    }

    Section("Labels") {
        ForEach(labels) { label in
            Label(label.name, systemImage: "tag")
        }
    }
}
.listStyle(.sidebar)
```

This gives us:
- System disclosure groups
- Liquid Glass selection highlights
- Proper keyboard navigation
- Standard sidebar width behavior

---

## 2. Toolbar Migration

### Current State

`DetailToolbarView` is an in-pane `HStack` with buttons for: Unsubscribe, Archive, Delete, Move to Inbox, and a "..." Menu (Reply, Forward, Star, Print, etc.). The window toolbar has only 2 items: sidebar toggle + compose.

### Target State

Move all email actions to the window `.toolbar {}` with Apple HIG placements:

```swift
.toolbar {
    // Leading group — navigation
    ToolbarItem(placement: .navigation) {
        // System sidebar toggle (automatic with NavigationSplitView)
    }

    // Primary actions — most-used email operations
    ToolbarItemGroup(placement: .primaryAction) {
        Button("Reply", systemImage: "arrowshape.turn.up.left") { ... }
        Button("Archive", systemImage: "archivebox") { ... }
        Button("Delete", systemImage: "trash") { ... }
    }

    ToolbarSpacer(.flexible)

    // Secondary actions
    ToolbarItemGroup(placement: .secondaryAction) {
        Button("Forward", systemImage: "arrowshape.turn.up.right") { ... }
        Button("Star", systemImage: "star") { ... }
        Button("Mark Unread", systemImage: "envelope.badge") { ... }
    }

    // Compose — confirmation action for glass prominent styling
    ToolbarItem(placement: .confirmationAction) {
        Button("Compose", systemImage: "square.and.pencil") { ... }
    }
}
```

### Changes

- `DetailToolbarView` is removed as a standalone view — its actions move to `.toolbar` modifiers on the NavigationSplitView or detail column
- Toolbar items are conditionally shown based on `selectedEmail != nil`
- The "..." overflow menu remains for less-common actions (Print, Download, Show Original, Spam)
- Unsubscribe stays contextual — shown only when applicable, perhaps as a toolbar item with `.hidden()` when not relevant

---

## 3. Settings Scene

### Current State

Settings are shown in a `SlidePanel` (25% window width) overlaid on the main content. Opened by the sidebar Settings button or Cmd+,.

### Target State

```swift
// SerifApp.swift
@main struct SerifApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }

        Settings {
            SettingsView()
        }
    }
}
```

`SettingsView` uses `TabView` with tabs:
- **General** — Theme picker, behavior (undo duration, refresh interval)
- **Accounts** — Account list with accent colors, add/remove
- **Signatures** — Per-alias signature management
- **Advanced** — Storage, Apple Intelligence toggle, developer settings

### Changes

- Remove `showSettings` from `PanelCoordinator`
- Remove settings panel from `SlidePanelsOverlay`
- Remove sidebar Settings button — Cmd+, is automatic
- `SerifCommands` settings command group no longer needs custom `panelCoordinator.openSettings()` — the system handles it
- All `SettingsCards` become tab content views with proper Form/GroupBox layouts instead of `.cardStyle()`
- ContactsSettingsCard stays in the Accounts tab

---

## 4. Accessibility

### Changes

Add throughout the view hierarchy:

**Email rows (`EmailRowView`):**
```swift
.accessibilityElement(children: .combine)
.accessibilityLabel("\(email.sender.name), \(email.subject), \(email.preview)")
.accessibilityAddTraits(email.isUnread ? [] : .isSelected)
.accessibilityHint("Double-tap to read")
```

**Sidebar folders:**
```swift
.accessibilityLabel("\(folder.name), \(unreadCount) unread")
```

**Toolbar buttons:** Already have `.help()` tooltips — add matching `.accessibilityLabel()` where the icon-only button lacks a text label.

**Avatar views:**
```swift
.accessibilityLabel("\(senderName) profile photo")
// or for initials: "\(senderName) avatar"
```

**Badges:**
```swift
.accessibilityLabel("\(count) unread messages")
```

**Toast views:**
```swift
.accessibilityAddTraits(.isStatusElement)
.accessibilityAnnouncement(message) // announce on appear
```

**General patterns:**
- `.accessibilityElement(children: .ignore)` on decorative elements (gradient overlays, skeleton shimmers)
- `.accessibilityRepresentation` for complex custom controls

---

## 5. Semantic Typography

### Mapping

| Current | Semantic Replacement |
|---------|---------------------|
| `.system(size: 22, weight: .bold)` (folder headings) | `.title2` |
| `.system(size: 20, weight: .bold)` (email subject) | `.title3` |
| `.system(size: 18, weight: .bold)` (panel titles) | `.headline` |
| `.system(size: 13, weight: .semibold)` (sender name) | `.body.weight(.semibold)` |
| `.system(size: 13)` (sidebar folder name) | `.body` |
| `.system(size: 12, weight: .medium)` (subject in row) | `.subheadline` |
| `.system(size: 12)` (category row) | `.subheadline` |
| `.system(size: 11)` (preview, date) | `.caption` |
| `.system(size: 10, weight: .semibold)` (badge) | `.caption2.weight(.semibold)` |
| `.system(size: 10, weight: .medium)` (label chip) | `.caption2` |
| `.system(size: 11, weight: .semibold)` (shortcuts help) | `.caption.weight(.semibold)` |

All done via `.font(.semantic)` — no `.system(size:)` remains in the codebase.

---

## 6. SwipeActions

### Current State

`SwipeableEmailRow` wraps each email row and uses `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` to detect horizontal swipes, with custom rubber-band physics, background color reveals, and dismissal animations.

### Target State

Remove `SwipeableEmailRow` entirely. Apply `.swipeActions()` directly on the email row in the `List`:

```swift
ForEach(emails) { email in
    EmailRowView(email: email)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Archive", systemImage: "archivebox") { archive(email) }
                .tint(.gray)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(email) }
        }
}
```

This gives us: system haptics, Liquid Glass swipe appearance, VoiceOver support, and correct List integration — all for free.

### Prerequisite

The email list must be a `List` (not a `ScrollView` with manual `VStack`). If `EmailListView` currently uses `ScrollView`, it needs to become a `List` to support `.swipeActions()`.

---

## 7. Menu Icons

### Changes

Add SF Symbol images to every command in `SerifCommands.swift`:

```swift
// Message menu
Button { archive() } label: { Label("Archive", systemImage: "archivebox") }
    .keyboardShortcut("e", modifiers: .command)
Button { delete() } label: { Label("Delete", systemImage: "trash") }
    .keyboardShortcut(.delete, modifiers: .command)
// ... etc for all menu items
```

Icon choices follow SF Symbols conventions used in Apple Mail:
- Archive → `archivebox`
- Delete → `trash`
- Star → `star` / `star.fill`
- Mark Read/Unread → `envelope.open` / `envelope.badge`
- Compose → `square.and.pencil`
- Refresh → `arrow.clockwise`
- Search → `magnifyingglass`
- Reply → `arrowshape.turn.up.left`
- Reply All → `arrowshape.turn.up.left.2`
- Forward → `arrowshape.turn.up.right`
- Move to Inbox → `tray.and.arrow.down`
- Print → `printer`
- Spam → `exclamationmark.shield`

---

## 8. Native WebView

### Current State

Email body HTML is rendered via a `WKWebView` wrapped in `NSViewRepresentable` (likely `EmailWebView` or similar).

### Target State

Replace with SwiftUI's native `WebView` (macOS 26+):

```swift
import WebKit

WebView(html: emailBodyHTML, baseURL: nil)
    .webViewAllowsLinkPreview(true)
    .webViewConfiguration { config in
        config.preferences.isElementFullscreenEnabled = false
    }
```

### Changes

- Remove the `NSViewRepresentable` wrapper
- Remove manual `WKNavigationDelegate` bridging for link interception — use SwiftUI modifiers
- Keep tracker-blocking content rules (these work with native WebView too)
- Keep the "open links in in-app browser" behavior via navigation policy

---

## 9. Spotlight & Handoff

### NSUserActivity (Handoff)

When the user reads an email, advertise an `NSUserActivity`:

```swift
.userActivity("com.serif.viewEmail", element: selectedEmail) { email, activity in
    activity.title = email.subject
    activity.isEligibleForHandoff = true
    activity.isEligibleForSearch = true
    activity.contentAttributeSet = attributeSet(for: email)
}
```

### Core Spotlight

Index recently viewed emails for Spotlight search:

```swift
import CoreSpotlight

func indexEmail(_ email: Email) {
    let attributes = CSSearchableItemAttributeSet(contentType: .emailMessage)
    attributes.subject = email.subject
    attributes.authorNames = [email.sender.name]
    attributes.textContent = email.preview
    attributes.contentCreationDate = email.date

    let item = CSSearchableItem(
        uniqueIdentifier: email.id,
        domainIdentifier: "emails",
        attributeSet: attributes
    )
    CSSearchableIndex.default().indexSearchableItems([item])
}
```

### Changes

- Add a `SpotlightIndexer` service class
- Call `indexEmail()` when an email is viewed
- Handle `NSUserActivity` continuation in `SerifApp` to navigate to the email
- Limit index to last 1000 viewed emails to avoid unbounded growth

---

## 10. Focus Management

### Changes

Add a `@FocusState` enum to `ContentView`:

```swift
enum AppFocus: Hashable {
    case sidebar
    case list
    case detail
}

@FocusState private var focus: AppFocus?
```

Apply `.focused($focus, equals:)` to each column's content. Add keyboard shortcuts:
- Tab → advance focus (sidebar → list → detail → sidebar)
- Shift+Tab → reverse

The sidebar `List`, email `List`, and detail `ScrollView` each declare their focus binding.

---

## Files Modified

| File | Changes |
|------|---------|
| `SerifApp.swift` | Add `Settings` scene, remove window style overrides |
| `ContentView.swift` | Replace HStack with NavigationSplitView, add toolbar, add FocusState |
| `SidebarView.swift` | Remove manual width/collapse/material, convert to List-based sidebar |
| `ListPaneView.swift` | Remove frame constraints, wire swipeActions |
| `DetailPaneView.swift` | Remove frame/clip/padding, remove DetailToolbarView usage |
| `DetailToolbarView.swift` | Remove (actions move to window toolbar) |
| `EmailRowView.swift` | Add accessibility, semantic fonts |
| `SwipeableEmailRow.swift` | Remove entirely |
| `EmailListView.swift` | Convert to List if ScrollView, add swipeActions |
| `SlidePanelsOverlay.swift` | Remove settings panel |
| `SettingsCardsView.swift` | Restructure into tabbed SettingsView |
| `SerifCommands.swift` | Add SF Symbol icons to all menu items |
| `AppCoordinator.swift` | Remove sidebarExpanded, minor cleanup |
| `PanelCoordinator.swift` | Remove showSettings |
| All views with text | Replace `.system(size:)` with semantic fonts |
| All interactive views | Add accessibility modifiers |
| Email web view wrapper | Replace with native WebView |
| New: `SpotlightIndexer.swift` | Core Spotlight + NSUserActivity |
| New: `SettingsView.swift` | Tabbed settings scene root |

## Non-Goals

- No custom Liquid Glass effects (`.glassEffect()`) on content — glass belongs on chrome only per HIG
- No new features — this is purely a modernization pass
- No data model changes — all changes are view/presentation layer
- No changes to onboarding flow (separate concern)
