# Theme Simplification Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace 16 custom themes with system-native Light/Dark appearance using SwiftUI semantic colors.

**Architecture:** Delete all custom theme infrastructure (Theme struct, ThemeManager, DefaultThemes, DesignSystem). Replace with a minimal AppearanceManager (system/light/dark preference) and SwiftUI semantic colors throughout all 45 view files. WKWebView files resolve NSColor semantics to hex for CSS injection.

**Tech Stack:** Swift 6.2, SwiftUI, macOS 26+, AppKit (NSColor for WKWebView CSS bridging)

**Spec:** `docs/superpowers/specs/2026-03-12-theme-simplification-design.md`

**Note:** This project has no view unit tests. Verification is via `xcodebuild` compilation. Each task ends with a build check.

---

## File Structure

### Create
- `Serif/Utilities/Color+Hex.swift` — `Color.init(hex:)` and `hexString` extensions (relocated from Theme.swift)
- `Serif/Theme/AppearanceManager.swift` — System/Light/Dark preference manager with migration

### Delete
- `Serif/Theme/Theme.swift` — 42-property struct + environment key
- `Serif/Theme/DefaultThemes.swift` — 16 theme definitions
- `Serif/Theme/ThemeManager.swift` — Theme manager + override system
- `Serif/Theme/DesignSystem.swift` — Custom font styles + `nonZeroOr` helper

### Modify (49 files)
- `Serif/Utilities/Constants.swift` — Remove old keys, add new
- `Serif/ContentView.swift` — Switch from ThemeManager to AppearanceManager
- `Serif/Views/Common/SlidePanelsOverlay.swift` — Remove themeManager parameter
- `Serif/Views/Common/ThemePickerView.swift` — Full rewrite to segmented picker
- `Serif/Views/Components/CardStyle.swift` — Use `.regularMaterial`
- `Serif/Views/Components/BadgeView.swift` — Remove theme
- `Serif/Views/EmailDetail/HTMLEmailView.swift` — NSColor resolution for CSS
- `Serif/Views/Common/WebRichTextEditor.swift` — NSColor resolution for CSS
- `Serif/Views/Common/WebRichTextEditorRepresentable.swift` — Remove Theme parameter
- `Serif/ViewModels/AppCoordinator.swift` — Inline `nonZeroOr`
- 39 remaining view files — Mechanical `theme.foo` → SwiftUI semantic replacement

---

## Task 1: Foundation — Create New Files

**Files:**
- Create: `Serif/Utilities/Color+Hex.swift`
- Create: `Serif/Theme/AppearanceManager.swift`
- Modify: `Serif/ViewModels/AppCoordinator.swift` (inline `nonZeroOr`)
- Modify: `Serif/Utilities/Constants.swift`

These files are additive — nothing breaks.

- [ ] **Step 1: Create `Color+Hex.swift`**

Extract the `Color` extensions from `Theme.swift` into a standalone utility file.

```swift
// Serif/Utilities/Color+Hex.swift
import SwiftUI

extension Color {
    /// Converts this Color to a hex string (#RRGGBB).
    var hexString: String {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(nsColor.redComponent * 255)
        let g = Int(nsColor.greenComponent * 255)
        let b = Int(nsColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
```

- [ ] **Step 2: Create `AppearanceManager.swift`**

```swift
// Serif/Theme/AppearanceManager.swift
import SwiftUI

@Observable
@MainActor
final class AppearanceManager {
    enum Preference: String, CaseIterable, Sendable {
        case system, light, dark
    }

    var preference: Preference {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: UserDefaultsKey.appearancePreference)
        }
    }

    var colorScheme: ColorScheme? {
        switch preference {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: UserDefaultsKey.appearancePreference)
        if let stored, let pref = Preference(rawValue: stored) {
            self.preference = pref
        } else {
            // Migration: map old theme to appearance preference
            let oldThemeId = UserDefaults.standard.string(forKey: "selectedThemeId") ?? "midnight"
            let lightThemes = ["light", "paper", "violet", "mono", "ivory"]
            self.preference = lightThemes.contains(oldThemeId) ? .light : .dark
            UserDefaults.standard.removeObject(forKey: "selectedThemeId")
            UserDefaults.standard.removeObject(forKey: "themeOverrides")
            UserDefaults.standard.set(preference.rawValue, forKey: UserDefaultsKey.appearancePreference)
        }
    }
}
```

- [ ] **Step 3: Update `Constants.swift`**

Remove `selectedThemeId` and `themeOverrides`. Add `appearancePreference`.

In `Serif/Utilities/Constants.swift`, replace lines 8-9:
```swift
    static let selectedThemeId = "selectedThemeId"
    static let themeOverrides = "themeOverrides"
```
With:
```swift
    static let appearancePreference = "appearancePreference"
```

- [ ] **Step 4: Inline `nonZeroOr` in `AppCoordinator.swift`**

In `Serif/ViewModels/AppCoordinator.swift`, replace at line 44:
```swift
    var undoDuration: Int = UserDefaults.standard.integer(forKey: UserDefaultsKey.undoDuration).nonZeroOr(5) {
```
With:
```swift
    var undoDuration: Int = { let v = UserDefaults.standard.integer(forKey: UserDefaultsKey.undoDuration); return v != 0 ? v : 5 }() {
```

And at line 47, replace:
```swift
    var refreshInterval: Int = UserDefaults.standard.integer(forKey: UserDefaultsKey.refreshInterval).nonZeroOr(120) {
```
With:
```swift
    var refreshInterval: Int = { let v = UserDefaults.standard.integer(forKey: UserDefaultsKey.refreshInterval); return v != 0 ? v : 120 }() {
```

- [ ] **Step 5: Verify build**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (new files compile, old files still exist)

- [ ] **Step 6: Commit**

```
git add Serif/Utilities/Color+Hex.swift Serif/Theme/AppearanceManager.swift Serif/Utilities/Constants.swift Serif/ViewModels/AppCoordinator.swift
git commit -m "feat: add AppearanceManager and Color+Hex utilities for theme migration"
```

---

## Task 2: Migrate Components (CardStyle + BadgeView)

**Files:**
- Modify: `Serif/Views/Components/CardStyle.swift`
- Modify: `Serif/Views/Components/BadgeView.swift`

**Depends on:** Task 1

- [ ] **Step 1: Rewrite `CardStyle.swift`**

Replace the entire file contents with:

```swift
import SwiftUI

/// A view modifier that applies the standard settings-card styling.
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }
}

extension View {
    /// Wraps the view in a styled settings card.
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}
```

- [ ] **Step 2: Update `BadgeView.swift`**

Read the file first. Remove `@Environment(\.theme) private var theme`. Replace:
- `theme.sidebarBadge` → `.fill.quaternary`
- `theme.sidebarBadgeText` → `.primary`

Any other `theme.` references per the mapping in the spec.

- [ ] **Step 3: Verify build**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```
git add Serif/Views/Components/
git commit -m "refactor: migrate CardStyle and BadgeView to system semantics"
```

---

## Task 3: Migrate Sidebar Views

**Files:**
- Modify: `Serif/Views/Sidebar/SidebarView.swift`
- Modify: `Serif/Views/Sidebar/SidebarRowViews.swift` (25 theme refs — most complex)
- Modify: `Serif/Views/Sidebar/AccountSwitcherView.swift`

**Depends on:** Task 1

**Color mapping for sidebar-specific properties:**
| Old | New |
|-----|-----|
| `theme.sidebarBackground` | Remove (system default) |
| `theme.sidebarText` | `.foregroundStyle(.primary)` |
| `theme.sidebarTextHover` | `.foregroundStyle(.primary)` |
| `theme.sidebarTextMuted` | `.foregroundStyle(.secondary)` |
| `theme.sidebarAccent` | `.tint` |
| `theme.sidebarBadge` | `.fill.quaternary` |
| `theme.sidebarBadgeText` | `.primary` |
| `theme.sidebarHover` | `.fill.quaternary` (or remove, let system handle) |
| `theme.sidebarSelectedBg` | `.tint.opacity(0.15)` |
| `theme.accentPrimary` | `.tint` |
| `theme.textPrimary` | `.foregroundStyle(.primary)` |
| `theme.textSecondary` | `.foregroundStyle(.secondary)` |
| `theme.textTertiary` | `.foregroundStyle(.tertiary)` |
| `theme.hoverBackground` | `.fill.quaternary` |
| `theme.listBackground` | Remove (system default) |
| `theme.divider` | Use `Divider()` or `.separator` |

- [ ] **Step 1: Migrate `SidebarView.swift`**

Read the file. Remove `@Environment(\.theme) private var theme`. Replace all `theme.` references per mapping above.

- [ ] **Step 2: Migrate `SidebarRowViews.swift`**

Read the file. This has 25 theme references including sidebar computed properties. Remove `@Environment(\.theme) private var theme`. Replace all references. Also replace `.font(.serifSmall)` → `.font(.footnote)`, `.font(.serifBadge)` → `.font(.caption2.weight(.semibold))`, `.font(.serifSmallMedium)` → `.font(.footnote.weight(.medium))`.

- [ ] **Step 3: Migrate `AccountSwitcherView.swift`**

Read the file. Remove theme environment. Replace references.

- [ ] **Step 4: Verify build**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```
git add Serif/Views/Sidebar/
git commit -m "refactor: migrate sidebar views to system semantic colors"
```

---

## Task 4: Migrate Email List Views

**Files:**
- Modify: `Serif/Views/EmailList/EmailListView.swift` (19 refs)
- Modify: `Serif/Views/EmailList/EmailRowView.swift` (11 refs)
- Modify: `Serif/Views/EmailList/EmailHoverSummaryView.swift` (9 refs)
- Modify: `Serif/Views/EmailList/BulkActionBarView.swift` (9 refs)
- Modify: `Serif/Views/EmailList/SwipeableEmailRow.swift` (4 refs)

**Depends on:** Task 1

**Standard color mapping (applies to all view migrations):**
| Old | New |
|-----|-----|
| `theme.textPrimary` | `.primary` (when used with `.foregroundStyle()`/`.foregroundColor()`) |
| `theme.textSecondary` | `.secondary` |
| `theme.textTertiary` | `.tertiary` |
| `theme.textInverse` | `.white` |
| `theme.accentPrimary` | `.tint` |
| `theme.accentSecondary` | `.secondary` |
| `theme.detailBackground` | Remove or use system default |
| `theme.listBackground` | Remove or use system default |
| `theme.cardBackground` | `.quinary` or `.regularMaterial` |
| `theme.selectedCardBackground` | `.tint.opacity(0.1)` |
| `theme.hoverBackground` | `.fill.quaternary` |
| `theme.searchBarBackground` | `.quinary` |
| `theme.border` | `.separator` |
| `theme.divider` | `.separator` |
| `theme.unreadIndicator` | `.blue` |
| `theme.attachmentBackground` | `.fill.quaternary` |
| `theme.avatarRing` | `.tint` |
| `theme.destructive` | `.red` |
| `theme.buttonPrimary` | `.tint` |
| `theme.buttonSecondary` | `.secondary` |
| `theme.inputBackground` | `.quinary` |
| `theme.tagBackground` | `.fill.quaternary` |

For each file: read it, remove `@Environment(\.theme) private var theme`, replace all `theme.` refs per this mapping.

- [ ] **Step 1: Migrate `EmailListView.swift`** (has **2** `@Environment(\.theme)` declarations — remove both)
- [ ] **Step 2: Migrate `EmailRowView.swift`** (also remove `.environment(\.theme, theme)` at the `EmailHoverSummaryView` call site)
- [ ] **Step 3: Migrate `EmailHoverSummaryView.swift`**
- [ ] **Step 4: Migrate `BulkActionBarView.swift`**
- [ ] **Step 5: Migrate `SwipeableEmailRow.swift`**

- [ ] **Step 6: Verify build**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 7: Commit**

```
git add Serif/Views/EmailList/
git commit -m "refactor: migrate email list views to system semantic colors"
```

---

## Task 5: Migrate Email Detail Views

**Files:**
- Modify: `Serif/Views/EmailDetail/EmailDetailView.swift` (13 refs)
- Modify: `Serif/Views/EmailDetail/ReplyBarView.swift` (22 refs)
- Modify: `Serif/Views/EmailDetail/OriginalMessageView.swift` (23 refs)
- Modify: `Serif/Views/EmailDetail/CalendarInviteCardView.swift` (15 refs)
- Modify: `Serif/Views/EmailDetail/LabelEditorView.swift` (10 refs)
- Modify: `Serif/Views/EmailDetail/DetailToolbarView.swift` (6 refs)
- Modify: `Serif/Views/EmailDetail/GmailThreadMessageView.swift` (6 refs)
- Modify: `Serif/Views/EmailDetail/AttachmentChipView.swift` (6 refs)
- Modify: `Serif/Views/EmailDetail/TrackerBannerView.swift` (5 refs)
- Modify: `Serif/Views/EmailDetail/SenderInfoPopover.swift` (5 refs)
- Modify: `Serif/Views/EmailDetail/AttachmentPreviewView.swift` (19 refs)
- Modify: `Serif/Views/EmailDetail/EmailDetailSkeletonView.swift` (2 refs)
- Modify: `Serif/Views/EmailDetail/DetailPaneView.swift` (1 ref)

**Depends on:** Task 1

Same color mapping as Task 4. For each file: read it, remove `@Environment(\.theme)`, replace all `theme.` references.

- [ ] **Step 1: Migrate `ReplyBarView.swift`** (22 refs — start with complex ones)
- [ ] **Step 2: Migrate `OriginalMessageView.swift`** (23 refs)
- [ ] **Step 3: Migrate `AttachmentPreviewView.swift`** (19 refs)
- [ ] **Step 4: Migrate `CalendarInviteCardView.swift`** (15 refs)
- [ ] **Step 5: Migrate `EmailDetailView.swift`** (13 refs — also remove `.environment(\.theme, theme)` at `SenderInfoPopover` call site)
- [ ] **Step 6: Migrate `LabelEditorView.swift`** (10 refs)
- [ ] **Step 7: Migrate `DetailToolbarView.swift`**
- [ ] **Step 8: Migrate `GmailThreadMessageView.swift`**
- [ ] **Step 9: Migrate `AttachmentChipView.swift`**
- [ ] **Step 10: Migrate `TrackerBannerView.swift`**
- [ ] **Step 11: Migrate `SenderInfoPopover.swift`**
- [ ] **Step 12: Migrate `EmailDetailSkeletonView.swift`**
- [ ] **Step 13: Migrate `DetailPaneView.swift`**

- [ ] **Step 14: Verify build**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 15: Commit**

```
git add Serif/Views/EmailDetail/
git commit -m "refactor: migrate email detail views to system semantic colors"
```

---

## Task 6: Migrate Common Views

**Files:**
- Modify: `Serif/Views/Common/SettingsCardsView.swift` (34 refs)
- Modify: `Serif/Views/Common/DebugMenuView.swift` (34 refs)
- Modify: `Serif/Views/Common/InAppBrowserView.swift` (13 refs)
- Modify: `Serif/Views/Common/AccountsSettingsView.swift` (9 refs)
- Modify: `Serif/Views/Common/FormattingToolbar.swift` (9 refs)
- Modify: `Serif/Views/Common/UndoToastView.swift` (8 refs)
- Modify: `Serif/Views/Common/ShortcutsHelpView.swift` (6 refs)
- Modify: `Serif/Views/Common/SlidePanel.swift` (5 refs)
- Modify: `Serif/Views/Common/SearchBarView.swift` (4 refs)
- Modify: `Serif/Views/Common/AccountAvatarBubble.swift` (3 refs)
- Modify: `Serif/Views/Common/LabelChipView.swift` (2 refs)
- Modify: `Serif/Views/Common/ToastOverlayView.swift` (2 refs)
- Modify: `Serif/Views/Common/AvatarView.swift`

**Depends on:** Task 1

Same color mapping. Also replace DesignSystem fonts:
- `.font(.serifTitle)` → `.font(.headline)`
- `.font(.serifBody)` → `.font(.body)`
- `.font(.serifLabel)` → `.font(.callout)`
- `.font(.serifCaption)` → `.font(.caption)`
- `.font(.serifSmall)` → `.font(.footnote)`
- `.font(.serifSmallMedium)` → `.font(.footnote.weight(.medium))`
- `.font(.serifMono)` → `.font(.caption.monospaced().weight(.medium))`
- `.font(.serifBadge)` → `.font(.caption2.weight(.semibold))`

Note: `SettingsCardsView.swift` and `SignatureEditorView.swift` use DesignSystem fonts.

- [ ] **Step 1: Migrate `SettingsCardsView.swift`** (34 refs — has **7** `@Environment(\.theme)` declarations across 7 structs, remove all)
- [ ] **Step 2: Migrate `DebugMenuView.swift`** (34 refs)
- [ ] **Step 3: Migrate `InAppBrowserView.swift`** (13 refs)
- [ ] **Step 4: Migrate `AccountsSettingsView.swift`** (9 refs)
- [ ] **Step 5: Migrate `FormattingToolbar.swift`** (9 refs — has **2** `@Environment(\.theme)` declarations, remove both)
- [ ] **Step 6: Migrate `UndoToastView.swift`** (8 refs — file contains **2 structs**: `OfflineToastView` and `UndoToastView`, each with its own `@Environment(\.theme)`, remove both)
- [ ] **Step 7: Migrate `ShortcutsHelpView.swift`**
- [ ] **Step 8: Migrate `SlidePanel.swift`**
- [ ] **Step 9: Migrate `SearchBarView.swift`**
- [ ] **Step 10: Migrate `AccountAvatarBubble.swift`**
- [ ] **Step 11: Migrate `LabelChipView.swift`**
- [ ] **Step 12: Migrate `ToastOverlayView.swift`**
- [ ] **Step 13: Migrate `AvatarView.swift`**

- [ ] **Step 14: Verify build**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 15: Commit**

```
git add Serif/Views/Common/
git commit -m "refactor: migrate common views to system semantic colors"
```

---

## Task 7: Migrate Compose + Attachment + Settings Views

**Files:**
- Modify: `Serif/Views/Compose/ComposeView.swift` (23 refs)
- Modify: `Serif/Views/Compose/AutocompleteTextField.swift` (8 refs)
- Modify: `Serif/Views/Attachments/AttachmentExplorerView.swift` (14 refs)
- Modify: `Serif/Views/Attachments/AttachmentCardView.swift` (7 refs)
- Modify: `Serif/Views/Settings/SignatureEditorView.swift` (8 refs)

**Depends on:** Task 1

Same color + font mapping as previous tasks.

- [ ] **Step 1: Migrate `ComposeView.swift`**
- [ ] **Step 2: Migrate `AutocompleteTextField.swift`**
- [ ] **Step 3: Migrate `AttachmentExplorerView.swift`**
- [ ] **Step 4: Migrate `AttachmentCardView.swift`**
- [ ] **Step 5: Migrate `SignatureEditorView.swift`** (also uses DesignSystem fonts)

- [ ] **Step 6: Verify build**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 7: Commit**

```
git add Serif/Views/Compose/ Serif/Views/Attachments/ Serif/Views/Settings/
git commit -m "refactor: migrate compose, attachment, and settings views to system semantic colors"
```

---

## Task 8: Migrate WKWebView Files (Special Handling)

**Files:**
- Modify: `Serif/Views/EmailDetail/HTMLEmailView.swift`
- Modify: `Serif/Views/Common/WebRichTextEditorRepresentable.swift`
- Modify: `Serif/Views/Common/WebRichTextEditor.swift` (parent view that passes `theme:`)

**Depends on:** Task 1

These files inject theme colors as CSS hex strings into WKWebView content. They cannot use SwiftUI semantic colors directly — they need resolved `NSColor` hex values.

- [ ] **Step 1: Migrate `HTMLEmailView.swift`**

Read the file. The key change is replacing `theme.textPrimary.hexString` with a resolved NSColor hex.

Remove `@Environment(\.theme) private var theme`.
Add `@Environment(\.colorScheme) private var colorScheme`.

Replace the `textHex` resolution in `updateNSView`:
```swift
// Old:
let textHex = theme.textPrimary.hexString

// New:
let textHex = NSColor.textColor.usingColorSpace(.sRGB).map {
    String(format: "#%02X%02X%02X",
        Int($0.redComponent * 255),
        Int($0.greenComponent * 255),
        Int($0.blueComponent * 255))
} ?? "#FFFFFF"
```

Update the cache key to use `colorScheme` instead of `textHex` for invalidation:
```swift
let cacheKey = "\(html)|\(colorScheme)"
```

- [ ] **Step 2: Migrate `WebRichTextEditorRepresentable.swift`**

Read the file. Remove the `var theme: Theme` property. Add `@Environment(\.colorScheme) private var colorScheme`.

Replace theme color hex strings with resolved NSColor values:
```swift
// Helper at file level or as a static method:
private func resolvedHex(_ nsColor: NSColor) -> String {
    nsColor.usingColorSpace(.sRGB).map {
        String(format: "#%02X%02X%02X",
            Int($0.redComponent * 255),
            Int($0.greenComponent * 255),
            Int($0.blueComponent * 255))
    } ?? "#000000"
}
```

In `makeNSView` and `updateNSView`, replace:
- `theme.textPrimary.hexString` → `resolvedHex(.textColor)`
- `theme.accentPrimary.hexString` → `resolvedHex(.controlAccentColor)`
- `theme.textTertiary.hexString` → `resolvedHex(.tertiaryLabelColor)`

- [ ] **Step 3: Update `WebRichTextEditor.swift`**

Read this file — it's the parent view that creates `WebRichTextEditorRepresentable` and passes `theme:`. Remove the `theme:` argument from the call site. Remove `@Environment(\.theme) private var theme` if present.

- [ ] **Step 4: Verify build**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```
git add Serif/Views/EmailDetail/HTMLEmailView.swift Serif/Views/Common/WebRichTextEditor*.swift
git commit -m "refactor: migrate WKWebView files to NSColor-resolved semantic colors"
```

---

## Task 9: Rewrite ThemePickerView + Update SlidePanelsOverlay + ContentView

**Files:**
- Modify: `Serif/Views/Common/ThemePickerView.swift` (full rewrite)
- Modify: `Serif/Views/Common/SlidePanelsOverlay.swift`
- Modify: `Serif/ContentView.swift`

**Depends on:** Tasks 2-8 (all view migrations complete)

- [ ] **Step 1: Rewrite `ThemePickerView.swift`**

Replace the entire file with:

```swift
import SwiftUI

struct ThemePickerView: View {
    @Bindable var appearanceManager: AppearanceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance")
                .font(.headline)

            Picker("Appearance", selection: $appearanceManager.preference) {
                Text("System").tag(AppearanceManager.Preference.system)
                Text("Light").tag(AppearanceManager.Preference.light)
                Text("Dark").tag(AppearanceManager.Preference.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .cardStyle()
    }
}
```

- [ ] **Step 2: Update `SlidePanelsOverlay.swift`**

Read the file.

Replace `var themeManager: ThemeManager` (line 6) with `var appearanceManager: AppearanceManager`.

Remove `@Environment(\.theme) private var theme` (line 21).

In `settingsPanel`, replace `ThemePickerView(themeManager: themeManager)` with `ThemePickerView(appearanceManager: appearanceManager)`.

Remove all `.environment(\.theme, theme)` modifiers (lines 63, 73, 84, 106, 131, 151).

Replace `ProgressView().tint(theme.textTertiary)` (lines 100, 124) with `ProgressView()`.

- [ ] **Step 3: Update `ContentView.swift`**

Read the file.

Replace `@State private var themeManager = ThemeManager.shared` with `@State private var appearanceManager = AppearanceManager()`.

In `body`, replace:
```swift
.environment(\.theme, themeManager.currentTheme)
.preferredColorScheme(themeManager.currentTheme.isLight ? .light : .dark)
.background(themeManager.currentTheme.detailBackground)
```
With:
```swift
.preferredColorScheme(appearanceManager.colorScheme)
```

Remove the three `.environment(\.theme, themeManager.currentTheme)` lines on the toast overlays (lines 99, 103, 107).

In `SlidePanelsOverlay(...)`, replace `themeManager: themeManager` with `appearanceManager: appearanceManager`.

In `toolbarContent`, replace `Image(systemName: "square.and.pencil").foregroundColor(themeManager.currentTheme.textPrimary)` with `Image(systemName: "square.and.pencil")`.

In `sidebarToggleButton`, replace `.foregroundColor(themeManager.currentTheme.textSecondary)` with `.foregroundStyle(.secondary)`.

- [ ] **Step 4: Verify build**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```
git add Serif/Views/Common/ThemePickerView.swift Serif/Views/Common/SlidePanelsOverlay.swift Serif/ContentView.swift
git commit -m "refactor: rewrite ThemePickerView, update ContentView to use AppearanceManager"
```

---

## Task 10: Delete Old Theme Files

**Files:**
- Delete: `Serif/Theme/Theme.swift`
- Delete: `Serif/Theme/DefaultThemes.swift`
- Delete: `Serif/Theme/ThemeManager.swift`
- Delete: `Serif/Theme/DesignSystem.swift`

**Depends on:** Task 9 (all references to Theme/ThemeManager removed)

- [ ] **Step 1: Delete old files**

```bash
rm Serif/Theme/Theme.swift Serif/Theme/DefaultThemes.swift Serif/Theme/ThemeManager.swift Serif/Theme/DesignSystem.swift
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED — all references have been migrated.

If build fails, check error output for remaining `Theme` or `ThemeManager` references and fix them.

- [ ] **Step 3: Commit**

```
git add -A
git commit -m "refactor: delete legacy theme system (Theme, DefaultThemes, ThemeManager, DesignSystem)"
```

---

## Task Dependency Graph

```
Task 1 (Foundation)
  ├── Task 2 (Components) ──────────┐
  ├── Task 3 (Sidebar) ─────────────┤
  ├── Task 4 (Email List) ──────────┤
  ├── Task 5 (Email Detail) ────────┼── Task 9 (ThemePickerView + ContentView) ── Task 10 (Delete)
  ├── Task 6 (Common) ──────────────┤
  ├── Task 7 (Compose/Attach/Set) ──┤
  └── Task 8 (WKWebView) ───────────┘
```

Tasks 2-8 are **independent** and can execute in parallel.
Task 9 depends on all of 2-8.
Task 10 depends on 9.
