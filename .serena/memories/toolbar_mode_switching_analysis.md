# Toolbar Button Structure & Mode Switching Analysis

## Issue
Mail-related toolbar buttons (top-right area) are still visible when in Calendar mode. They should be hidden or swapped for calendar-specific buttons.

## Key Components

### 1. Mode State Definition
**File:** `/Users/votan/coding/gmail/Vik/Utilities/Constants.swift` (Line 67)
```swift
enum AppViewMode: String, Sendable { case mail, calendar }
```

**Access via:** `coordinator.calendar.viewMode` (observable property in `CalendarCoordinator`)

### 2. Toolbar Definition (ROOT ISSUE)
**File:** `/Users/votan/coding/gmail/Vik/ContentView.swift` (Line 37, Lines 223-264)

The toolbar is defined ONCE in ContentView.body via ToolbarWrapper:
```swift
.toolbar { ToolbarWrapper(coordinator: coordinator, ...) }
```

**ToolbarWrapper** (lines 223-264):
- Is a private struct conforming to `ToolbarContent`
- Defines TWO toolbar sections:
  1. **Sidebar toggle** (navigation placement) - Line 230: `ToolbarItem(placement: .navigation)`
  2. **EmailToolbarItems** (primaryAction placement) - Line 244: Shows mail-specific buttons
- **PROBLEM:** EmailToolbarItems is ALWAYS rendered regardless of viewMode

### 3. EmailToolbarItems (The Problem Child)
**File:** `/Users/votan/coding/gmail/Vik/Views/Common/EmailToolbarItems.swift` (Lines 1-121)

Structure:
- Conditionally shows buttons IF an email is selected: `if let email = selectedEmail`
- Shows compose button: `.primaryAction` placement (line 29)
- Shows reply/archive/delete/snooze when email selected: `.primaryAction` placement (lines 41-66)
- Shows more menu: `.automatic` placement (line 89)

**CRITICAL:** This component:
1. Does NOT check `coordinator.calendar.viewMode`
2. Always renders toolbar items if mail-related state exists
3. Only hides buttons based on email selection, not mode

### 4. Mode Switching Implementation
**Files:**
- **CalendarCoordinator:** `/Users/votan/coding/gmail/Vik/ViewModels/CalendarCoordinator.swift` (Lines 17-31)
  - `viewMode` property (Line 9): Initial value is `.mail`
  - `switchToCalendar()` method (Line 17)
  - `switchToMail()` method (Line 29)

- **AppCoordinator:** `/Users/votan/coding/gmail/Vik/ViewModels/AppCoordinator.swift` (Lines 116-117)
  - Delegates to CalendarCoordinator: 
    - `switchToCalendar()` → `calendar.switchToCalendar(db:)`
    - `switchToMail()` → `calendar.switchToMail()`

### 5. Keyboard Shortcuts (⌘1 / ⌘2)
**File:** `/Users/votan/coding/gmail/Vik/Views/Common/VikCommands.swift` (Lines 178-191)

```swift
// MARK: - View Menu
private var viewMenu: some Commands {
    CommandMenu("View") {
        Button {
            coordinator?.switchToMail()
        } label: {
            Label("Mail", systemImage: "envelope")
        }
        .keyboardShortcut("1", modifiers: .command)  // ⌘1

        Button {
            coordinator?.switchToCalendar()
        } label: {
            Label("Calendar", systemImage: "calendar")
        }
        .keyboardShortcut("2", modifiers: .command)  // ⌘2
    }
}
```

### 6. Mode-Aware Content Display
**File:** `/Users/votan/coding/gmail/Vik/ContentView.swift` (Lines 310-340)

**ModeContentView** properly switches main content:
```swift
if coordinator.calendar.viewMode == .calendar,
   let calendarVM = coordinator.calendar.calendarViewModel {
    CalendarContainer(...)  // Shows calendar UI
} else {
    ListDetailSplitView(...)  // Shows mail UI (list + detail)
}
```

This is where mail/calendar content switches correctly, but toolbar does NOT switch.

### 7. Sidebar Mode Switcher (Working Correctly)
**File:** `/Users/votan/coding/gmail/Vik/Views/Sidebar/SidebarView.swift` (Lines 117-146)

```swift
private var modeSwitcher: some View {
    // Shows Mail and Calendar buttons
    // Calls onSwitchToMail() / onSwitchToCalendar()
}
```

This correctly shows which mode is active and allows switching.

## Root Cause Summary

The toolbar is attached to ContentView.body GLOBALLY via `.toolbar { ToolbarWrapper(...) }` and:

1. **ToolbarWrapper** renders **EmailToolbarItems** unconditionally
2. **EmailToolbarItems** contains mail-specific buttons (Compose, Reply, Archive, Delete, Snooze)
3. These buttons are only hidden based on email selection, NOT mode
4. When in Calendar mode, these mail buttons remain visible if any mail data exists

## Solution Strategy

### Option A: Conditional Rendering in ToolbarWrapper (Recommended)
Modify **ToolbarWrapper.body** to check `coordinator.calendar.viewMode`:
```swift
var body: some ToolbarContent {
    // Sidebar toggle (always show)
    ToolbarItem(placement: .navigation) { ... }
    
    // Only show mail toolbar items when in mail mode
    if coordinator.calendar.viewMode == .mail {
        EmailToolbarItems(...)
    } else {
        // Optionally: CalendarToolbarItems(...) for calendar-specific buttons
    }
}
```

### Option B: Calendar Toolbar Items
Create a parallel `CalendarToolbarItems` component for calendar-specific actions and swap them in ToolbarWrapper based on viewMode.

### Option C: Nested Mode Check
Add `viewMode` parameter to EmailToolbarItems and have it internally hide its content when not in mail mode.

## Files to Modify
1. **Primary:** `/Users/votan/coding/gmail/Vik/ContentView.swift` - ToolbarWrapper (lines 223-264)
2. **Secondary (optional):** `/Users/votan/coding/gmail/Vik/Views/Common/EmailToolbarItems.swift` - Add viewMode awareness
3. **New file (optional):** Create `CalendarToolbarItems.swift` for calendar-specific toolbar buttons

## Code Lines of Interest
- ContentView toolbar attachment: Line 37
- ToolbarWrapper definition: Lines 223-264
- EmailToolbarItems call: Line 244
- ModeContentView (reference for proper mode switching): Lines 310-340
- CalendarCoordinator.viewMode: CalendarCoordinator.swift Line 9
- switchToCalendar/switchToMail: AppCoordinator.swift Lines 116-117
- Keyboard shortcuts: VikCommands.swift Lines 178-191
- SidebarView mode switcher: SidebarView.swift Lines 117-146
