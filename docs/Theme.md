# Appearance & Design Tokens

System-integrated appearance management and centralized design token system following Apple's macOS 26 Liquid Glass spatial hierarchy.

## How It Works

`AppearanceManager` is an `@Observable` class that stores a single preference: System, Light, or Dark. It is owned by `ContentView` via `@State` and applied with `.preferredColorScheme()`.

- **System** (default): defers to macOS appearance (passes `nil` to `.preferredColorScheme()`)
- **Light / Dark**: forces the corresponding color scheme

All views use SwiftUI semantic colors (`.primary`, `.secondary`, `.tertiary`, `Color.accentColor`), materials, and Liquid Glass (`.glassEffect(.regular)`). No custom color definitions exist.

## Spatial Hierarchy

The UI follows a three-plane model:

| Plane | Material | Use |
|-------|----------|-----|
| **Base** | Solid/opaque (`.quinary` + `.separator` stroke via `CardStyle`) | Content cards, email body, settings cards |
| **Navigation** | `.glassEffect(.regular)` | Toolbar capsules, category tabs, bulk action bars |
| **Transient** | `.glassEffect(.regular)` + `.elevation(.transient)` via `floatingPanelStyle()` | Toasts, popovers, slide panels |

## Files

| File | Role |
|------|------|
| `AppearanceManager.swift` | Preference storage, UserDefaults persistence, migration from legacy theme system |
| `DesignTokens.swift` | Centralized design tokens and shared view modifiers (see below) |

## Design Tokens (`DesignTokens.swift`)

| Token | Values |
|-------|--------|
| `Spacing` | `xs` (4), `sm` (8), `md` (12), `lg` (16), `xl` (24), `xxl` (32) |
| `CornerRadius` | `sm` (6), `md` (12), `lg` (16) |
| `SerifAnimation` | `springDefault`, `springSnappy`, `springGentle` |
| `Typography` | `title`, `headline`, `subhead`, `body`, `bodyMedium`, `bodySemibold`, `caption`, `captionSmall` |

**View modifiers:**

| Modifier | Effect |
|----------|--------|
| `.elevation(.navigation / .transient / .elevated)` | Shadow scale (tight → wide) for spatial depth |
| `.selectableRowStyle(isSelected:isHovered:)` | Tint/primary/secondary foreground based on state |
| `.floatingPanelStyle()` | Liquid Glass + transient elevation for floating surfaces |

## Migration

`AppearanceManager.init()` detects the old `selectedThemeId` UserDefaults key and maps it to Light or Dark based on the theme's name. The old keys (`selectedThemeId`, `themeOverrides`) are removed after migration.

## Settings UI

`ThemePickerView` provides a segmented picker (System / Light / Dark) inside the Settings panel.
