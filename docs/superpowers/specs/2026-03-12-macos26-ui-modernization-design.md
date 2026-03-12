# macOS 26 UI/UX Modernization — Design Spec

## Overview

Modernize Serif's UI to fully adopt Apple's macOS 26 (Tahoe) design system — Liquid Glass, `NavigationSplitView`, system toolbar patterns, semantic typography, native components, and accessibility. The goal is to look and feel like a first-party Apple app.

## Scope

9 changes organized in 3 layers (built in dependency order):

### Layer 1: Foundation (everything else builds on this)

1. **NavigationSplitView migration** — replaces the manual `HStack(spacing: 0)` three-column layout
2. **Toolbar migration** — moves email actions to the window toolbar with HIG-correct placements

### Layer 2: Components (independent of each other, depend on Layer 1)

3. **Settings scene** — replaces SlidePanel settings with a proper `Settings` scene
4. **Accessibility** — adds labels, hints, traits, and element grouping throughout
5. **Semantic typography** — replaces all hardcoded `.system(size:)` with semantic text styles
6. **SwipeActions** — replaces custom NSEvent-based swipe with `.swipeActions()` (requires ScrollView→List conversion)
7. **Menu icons** — adds SF Symbols to all `SerifCommands` menu items

### Layer 3: New Capabilities (independent, depend on Layer 1)

8. **Spotlight & Handoff** — adds `NSUserActivity` and Core Spotlight indexing
9. **Focus management** — adds `@FocusState` pane navigation

### Dropped

- ~~**Native WebView**~~ — `HTMLEmailView.swift` documents why the native SwiftUI `WebView` cannot replace `WKWebView`: it requires user scripts (dark-mode DOM walking), script message handlers (image-load notifications for re-measurement), `evaluateJavaScript` (content height), and `WKNavigationDelegate` (link interception). None of these are exposed by the native API.

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

**Serif/ContentView.swift** (root-level, not in Views/):
- Replace `HStack(spacing: 0)` in `mainLayout` (lines 39-92) with `NavigationSplitView(columnVisibility:)`
- Replace coordinator's `sidebarExpanded` binding with `@State private var columnVisibility: NavigationSplitViewVisibility = .all`
- Remove custom sidebar toggle toolbar button — `NavigationSplitView` provides one automatically
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
- Remove `sidebarExpanded` property (line 30). This is passed as `@Binding var isExpanded: Bool` to `SidebarView` and used in ~15 places for collapsed-vs-expanded rendering. Since `SidebarView` is being rewritten as a `List`-based sidebar (no collapsed mode), all those conditional branches are removed along with the binding.
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
    // Navigation — system sidebar toggle is automatic with NavigationSplitView

    // Primary actions — most-used email operations (trailing, glass-styled)
    ToolbarItemGroup(placement: .primaryAction) {
        Button("Compose", systemImage: "square.and.pencil") { ... }
        Button("Reply", systemImage: "arrowshape.turn.up.left") { ... }
        Button("Archive", systemImage: "archivebox") { ... }
        Button("Delete", systemImage: "trash") { ... }
    }

    // Additional actions — less frequent operations
    ToolbarItemGroup(placement: .automatic) {
        Button("Forward", systemImage: "arrowshape.turn.up.right") { ... }
        Button("Star", systemImage: "star") { ... }
        Button("Mark Unread", systemImage: "envelope.badge") { ... }
    }
}
```

Note: `ToolbarSpacer` and `.secondaryAction` are not standard macOS SwiftUI APIs. Use `.primaryAction` for prominent trailing items and `.automatic` for others. The system handles grouping and glass styling.

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
- **Help button** moves to `SerifCommands` as a Help menu command (standard macOS location)
- **Debug button** moves to `SerifCommands` as a menu item under a Debug menu (only shown when `showDebugMenu` is enabled), or stays as a `.safeAreaInset(edge: .bottom)` in the sidebar if the developer toggle is on

---

## 4. Accessibility

### Changes

Add throughout the view hierarchy:

**Email rows (`EmailRowView`):**
```swift
.accessibilityElement(children: .combine)
.accessibilityLabel("\(email.sender.name), \(email.subject), \(email.preview)")
.accessibilityValue(email.isUnread ? "Unread" : "Read")
.accessibilityAddTraits(isSelected ? .isSelected : [])
.accessibilityHint("Double-tap to read")
```
Note: `.isSelected` indicates the currently focused/chosen row, not read state. Read/unread is communicated via `.accessibilityValue`.

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
.onAppear { AccessibilityNotification.Announcement(message).post() }
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

### Prerequisite — ScrollView to List Conversion (Major)

`EmailListView` currently uses `ScrollView + LazyVStack(spacing: 2)` (line 199 of `EmailListView.swift`). Converting to `List` is required for `.swipeActions()` but is a significant change because the current implementation includes:

- **Pull-to-refresh** via `PullToRefreshDetector` (custom `NSViewRepresentable` over-scroll detection) → Replace with `.refreshable { }` on `List`
- **Scroll-disable lock** via `scrollDisabled(swipeCoordinator.isSwipeActive)` → Remove (system swipe handles this)
- **Keyboard navigation** via `onKeyPress` for up/down/enter → `List(selection:)` provides this natively
- **Infinite scroll** via `Color.clear.onAppear` sentinel at bottom → Keep as `.onAppear` on the last row, or use `List` with `.task` modifier
- **Multi-select** with shift-click anchor logic → `List(selection: $selectedIDs)` where `selectedIDs` is `Set<String>` — multi-select is automatic, no additional modifier needed
- **Sort ordering** with debounced search → Stays as-is (data source logic, not view concern)
- **Custom row spacing** (2pt) → `.listRowSpacing(2)` or `.listStyle(.plain)` with row insets

This is the highest-risk change in the spec. The `List` conversion must preserve all existing functionality while adopting system behaviors.

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

## 8. Spotlight & Handoff

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

- Add a `SpotlightIndexer` service class in `Serif/Services/`
- Call `indexEmail()` from `AppCoordinator.handleSelectedEmailChange(_:)` when an email is viewed
- Handle `NSUserActivity` continuation via `.onContinueUserActivity("com.serif.viewEmail")` on the `NavigationSplitView` in `ContentView` — this has access to the `AppCoordinator` instance and can set `coordinator.selectedEmail` directly. No structural changes needed since `ContentView` already owns the coordinator.
- Limit index to last 1000 viewed emails to avoid unbounded growth

---

## 9. Focus Management

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
| `Serif/SerifApp.swift` | Add `Settings` scene, remove window style overrides |
| `Serif/ContentView.swift` | Replace HStack with NavigationSplitView, add toolbar, add FocusState, add `.onContinueUserActivity` |
| `Serif/Views/Sidebar/SidebarView.swift` | Remove manual width/collapse/material, convert to List-based sidebar, remove Settings/Help/Debug buttons |
| `Serif/Views/EmailList/ListPaneView.swift` | Remove frame constraints |
| `Serif/Views/EmailDetail/DetailPaneView.swift` | Remove frame/clip/padding, remove DetailToolbarView usage |
| `Serif/Views/EmailDetail/DetailToolbarView.swift` | Remove (actions move to window toolbar) |
| `Serif/Views/EmailList/EmailRowView.swift` | Add accessibility, semantic fonts |
| `Serif/Views/EmailList/SwipeableEmailRow.swift` | Remove entirely |
| `Serif/Views/EmailList/EmailListView.swift` | Convert ScrollView+LazyVStack to List (major — see Section 6), add swipeActions |
| `Serif/Views/Common/SlidePanelsOverlay.swift` | Remove settings panel |
| `Serif/Views/Common/SettingsCardsView.swift` | Restructure into tabbed SettingsView |
| `Serif/Views/Common/SerifCommands.swift` | Add SF Symbol icons to all menu items, add Help command |
| `Serif/ViewModels/AppCoordinator.swift` | Remove sidebarExpanded, call SpotlightIndexer on email view |
| `Serif/ViewModels/PanelCoordinator.swift` | Remove showSettings |
| All views with text | Replace `.system(size:)` with semantic fonts |
| All interactive views | Add accessibility modifiers |
| New: `Serif/Services/SpotlightIndexer.swift` | Core Spotlight indexing + NSUserActivity support |
| New: `Serif/Views/Settings/SettingsView.swift` | Tabbed settings scene root |

## Non-Goals

- No custom Liquid Glass effects (`.glassEffect()`) on content — glass belongs on chrome only per HIG
- No new features — this is purely a modernization pass
- No data model changes — all changes are view/presentation layer
- No changes to onboarding flow (separate concern)
