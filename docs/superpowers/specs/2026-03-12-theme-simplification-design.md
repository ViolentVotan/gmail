# Theme Simplification — System-Native Light/Dark Appearance

**Date:** 2026-03-12
**Status:** Approved

## Goal

Replace 16 custom themes (42 color properties each) with two system-native appearances (Light/Dark), using SwiftUI semantic colors and built-in text styles. The app should follow macOS system appearance by default with a user override option.

## Approach

Eliminate the custom `Theme` struct, `ThemeManager`, `DefaultThemes`, and `DesignSystem` entirely. All 45 files using `@Environment(\.theme)` switch from `theme.foo` to SwiftUI semantic equivalents. A minimal `AppearanceManager` handles the system/light/dark preference.

## AppearanceManager

Replaces `ThemeManager`. Single responsibility: store and apply the user's appearance preference.

```swift
@Observable @MainActor
final class AppearanceManager {
    enum Preference: String, CaseIterable { case system, light, dark }

    var preference: Preference {
        didSet { UserDefaults.standard.set(preference.rawValue, forKey: "appearancePreference") }
    }

    var colorScheme: ColorScheme? {
        switch preference {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: "appearancePreference")
        if let stored, let pref = Preference(rawValue: stored) {
            self.preference = pref
        } else {
            // Migration: map old theme to appearance preference
            let oldThemeId = UserDefaults.standard.string(forKey: "selectedThemeId") ?? "midnight"
            let lightThemes = ["light", "paper", "violet", "mono", "ivory"]
            self.preference = lightThemes.contains(oldThemeId) ? .light : .dark
            // Clean up legacy keys
            UserDefaults.standard.removeObject(forKey: "selectedThemeId")
            UserDefaults.standard.removeObject(forKey: "themeOverrides")
            UserDefaults.standard.set(preference.rawValue, forKey: "appearancePreference")
        }
    }
}
```

Applied at the app root: `.preferredColorScheme(appearanceManager.colorScheme)` — `nil` defers to macOS setting.

## Color Mapping

Every `theme.foo` reference is replaced with a SwiftUI semantic equivalent:

### Backgrounds

| Theme Property | SwiftUI Replacement |
|---|---|
| `sidebarBackground` | System default (NavigationSplitView) |
| `listBackground` | System default (List) |
| `detailBackground` | System default |
| `cardBackground` | `.background(.quinary)` or `.regularMaterial` |
| `selectedCardBackground` | System selection highlighting |
| `hoverBackground` | System hover |
| `searchBarBackground` | System text field style |

### Text

| Theme Property | SwiftUI Replacement |
|---|---|
| `textPrimary` | `.foregroundStyle(.primary)` |
| `textSecondary` | `.foregroundStyle(.secondary)` |
| `textTertiary` | `.foregroundStyle(.tertiary)` |
| `textInverse` | `.white` (deliberate simplification — used on tinted/accent backgrounds for button labels, swipe icons, etc.) |

### Accents

| Theme Property | SwiftUI Replacement |
|---|---|
| `accentPrimary` | `.tint` (system/app accent) |
| `accentSecondary` | `.secondary` |

### Borders & Dividers

| Theme Property | SwiftUI Replacement |
|---|---|
| `border` | `.foregroundStyle(.separator)` |
| `divider` | `Divider()` |

### Semantic Colors

| Theme Property | SwiftUI Replacement |
|---|---|
| `unreadIndicator` | `.tint` or `.blue` |
| `attachmentBackground` | `.fill.quaternary` |
| `avatarRing` | `.tint` |
| `destructive` | `.red` |

### Components

| Theme Property | SwiftUI Replacement |
|---|---|
| `buttonPrimary` | `.borderedProminent` button style |
| `buttonSecondary` | `.bordered` button style |
| `inputBackground` | System text field style |
| `tagBackground` | `.fill.quaternary` |

### Sidebar Computed Properties

All 8 computed properties removed (`sidebarText`, `sidebarAccent`, `sidebarHover`, `sidebarSelectedBg`, `sidebarBadge`, `sidebarBadgeText`, `sidebarTextHover`, `sidebarTextMuted`). Replacements:

| Sidebar Property | SwiftUI Replacement |
|---|---|
| `sidebarText` | `.foregroundStyle(.primary)` (vibrancy automatic in sidebar) |
| `sidebarTextHover` | System hover state |
| `sidebarTextMuted` | `.foregroundStyle(.secondary)` |
| `sidebarAccent` | `.tint` |
| `sidebarBadge` | `.badge()` modifier or `.tint` background |
| `sidebarBadgeText` | `.white` |
| `sidebarHover` | System hover highlighting |
| `sidebarSelectedBg` | `.listRowBackground` with system selection, or `.selected` state |

**Note:** `SidebarRowViews.swift`, `BadgeView.swift`, and `AccountSwitcherView.swift` use these extensively. The sidebar should use `List` with native selection where possible to get system vibrancy for free.

## WKWebView CSS Theming

`HTMLEmailView` and `WebRichTextEditorRepresentable` inject theme colors as CSS hex values into `WKWebView` content. Since SwiftUI semantic colors have no hex representation, use AppKit's resolved semantic colors:

```swift
// Resolve system colors to hex for CSS injection
let textColor = NSColor.textColor.usingColorSpace(.sRGB)!
let textHex = String(format: "#%02X%02X%02X",
    Int(textColor.redComponent * 255),
    Int(textColor.greenComponent * 255),
    Int(textColor.blueComponent * 255))

let accentColor = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
// ... same pattern
```

These resolve correctly for both light and dark mode. Re-inject CSS when `@Environment(\.colorScheme)` changes.

## Typography Mapping

Replace 8 custom `DesignSystem` font styles with SwiftUI built-in text styles:

| Custom Style | SwiftUI Replacement |
|---|---|
| `serifTitle` (14pt semibold) | `.headline` |
| `serifBody` (13pt regular) | `.body` |
| `serifLabel` (12pt medium) | `.callout` |
| `serifCaption` (12pt regular) | `.caption` |
| `serifSmall` (11pt regular) | `.footnote` |
| `serifSmallMedium` (11pt medium) | `.footnote.weight(.medium)` |
| `serifMono` (12pt monospaced) | `.caption.monospaced().weight(.medium)` |
| `serifBadge` (10pt semibold) | `.caption2.weight(.semibold)` |

**Note:** Some point sizes shift slightly (e.g., `.caption` is ~10pt vs 12pt, `.headline` is ~13pt vs 14pt). This is intentional — the app adopts macOS-standard text density rather than custom sizing. Inline `.font(.system(size:))` calls throughout views are **out of scope** for this change.

## Card Style Modifier

The `cardStyle()` modifier updates to:

```swift
.padding(20)
.background(.regularMaterial, in: .rect(cornerRadius: 12))
```

Padding preserved from original. The explicit shadow is removed — `.regularMaterial` provides its own depth via the macOS material system.

## File Changes

### Delete

- `Serif/Theme/Theme.swift` — 42-property struct, color utilities, environment key
- `Serif/Theme/DefaultThemes.swift` — 16 theme definitions
- `Serif/Theme/ThemeManager.swift` — theme selection, override system, singleton
- `Serif/Theme/DesignSystem.swift` — custom font styles

### Create

- `Serif/Theme/AppearanceManager.swift` — appearance preference manager
- `Serif/Utilities/Color+Hex.swift` — relocated `Color.init(hex:)` and `hexString` extensions from `Theme.swift` (used by `OnboardingView`, `GoogleLogo`, `AvatarView`, `AccountAvatarBubble`, `LabelChipView`, `AccountsSettingsView`, `SidebarRowViews`, `LabelEditorView`, `ReplyBarView`, `HTMLEmailView`, `WebRichTextEditorRepresentable`)

### Relocate

- `Int.nonZeroOr(_:)` from `DesignSystem.swift` → `Serif/Utilities/Extensions.swift` or inline at call site in `AppCoordinator.swift`

### Modify

- `ContentView.swift` — swap ThemeManager for AppearanceManager, remove `\.theme` environment, use `.preferredColorScheme()`
- `SlidePanelsOverlay.swift` — update parameter from `themeManager: ThemeManager` to `appearanceManager: AppearanceManager`
- `ThemePickerView.swift` — replace grid + customization with segmented picker (~20 lines)
- `Constants.swift` — remove `selectedThemeId`/`themeOverrides`, add `appearancePreference`
- `HTMLEmailView.swift` — replace `theme.foo.hexString` with resolved `NSColor` semantic colors
- `WebRichTextEditorRepresentable.swift` — same as above
- **45 view files** — mechanical replacement of `@Environment(\.theme)` and `theme.foo` references

## Settings UI

The theme section becomes a single segmented picker:

```swift
Picker("Appearance", selection: $appearanceManager.preference) {
    Text("System").tag(AppearanceManager.Preference.system)
    Text("Light").tag(AppearanceManager.Preference.light)
    Text("Dark").tag(AppearanceManager.Preference.dark)
}
.pickerStyle(.segmented)
```

## Migration

On first launch after update:
1. Read existing `selectedThemeId` from UserDefaults
2. Map to appearance: light themes (`light`, `paper`, `violet`, `mono`, `ivory`) → `.light`; dark themes → `.dark`; missing → `.dark` (original default was midnight)
3. Save new `appearancePreference` key
4. Remove legacy `selectedThemeId` and `themeOverrides` keys
5. Custom color overrides are silently discarded (no user notification needed — the feature is removed)

## What the App Gains

- Automatic macOS 26 liquid glass / material support
- Dynamic Type / accessibility scaling
- Correct vibrancy in sidebars, toolbars, popovers
- Zero maintenance — future macOS appearance changes work automatically
- ~860 lines of theme code removed

## Known Impact

- Views that relied on specific color contrasts (e.g., dark sidebar + light content in Violet/Mono themes) will look different. This is expected — the system handles sidebar vibrancy natively.
- Typography sizes shift slightly to match macOS standards. This changes visual density but improves consistency with the platform.
- `textInverse` → `.white` is a deliberate simplification. Verify visually at each call site during implementation.
