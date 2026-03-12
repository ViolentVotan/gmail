# Theme Simplification — System-Native Light/Dark Appearance

**Date:** 2026-03-12
**Status:** Approved

## Goal

Replace 16 custom themes (42 color properties each) with two system-native appearances (Light/Dark), using SwiftUI semantic colors and built-in text styles. The app should follow macOS system appearance by default with a user override option.

## Approach

Eliminate the custom `Theme` struct, `ThemeManager`, `DefaultThemes`, and `DesignSystem` entirely. All 47+ views switch from `theme.foo` to SwiftUI semantic equivalents. A minimal `AppearanceManager` handles the system/light/dark preference.

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
        let raw = UserDefaults.standard.string(forKey: "appearancePreference") ?? "system"
        self.preference = Preference(rawValue: raw) ?? .system
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
| `textInverse` | `.white` (on tinted backgrounds) |

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

All removed — `sidebarText`, `sidebarAccent`, `sidebarHover`, etc. System handles sidebar vibrancy natively.

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
| `serifMono` (12pt monospaced) | `.caption.monospaced()` |
| `serifBadge` (10pt semibold) | `.caption2.weight(.semibold)` |

## Card Style Modifier

The `cardStyle()` modifier updates from:

```swift
.background(theme.cardBackground)
```

To:

```swift
.background(.regularMaterial, in: .rect(cornerRadius: 12))
```

This provides macOS 26 material/glass appearance automatically.

## File Changes

### Delete

- `Serif/Theme/Theme.swift` — 42-property struct, color utilities, environment key
- `Serif/Theme/DefaultThemes.swift` — 16 theme definitions
- `Serif/Theme/ThemeManager.swift` — theme selection, override system, singleton
- `Serif/Theme/DesignSystem.swift` — custom font styles

### Create

- `Serif/Theme/AppearanceManager.swift` — appearance preference manager (~25 lines)

### Modify

- `ContentView.swift` — swap ThemeManager for AppearanceManager, remove `\.theme` environment, use `.preferredColorScheme()`
- `ThemePickerView.swift` — replace grid + customization with segmented picker (~20 lines)
- `Constants.swift` — remove `selectedThemeId`/`themeOverrides`, add `appearancePreference`
- **47 view files** — mechanical replacement of `@Environment(\.theme)` and `theme.foo` references

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

## What the App Gains

- Automatic macOS 26 liquid glass / material support
- Dynamic Type / accessibility scaling
- Correct vibrancy in sidebars, toolbars, popovers
- Zero maintenance — future macOS appearance changes work automatically
- ~800 lines of theme code removed

## Known Impact

Views that relied on specific color contrasts (e.g., dark sidebar + light content in Violet/Mono themes) will look different. This is expected and desired — the system handles sidebar vibrancy natively.
