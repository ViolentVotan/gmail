# Appearance & Design Tokens

System-integrated appearance management and centralized design token system following Apple's macOS 26 Liquid Glass spatial hierarchy.

## How It Works

`AppearanceManager` is an `@Observable` class that stores a single preference: System, Light, or Dark. It is owned by `SerifApp` via `@State` and passed to both `ContentView` and `SettingsView`, then applied with `.preferredColorScheme()`.

- **System** (default): defers to macOS appearance (passes `nil` to `.preferredColorScheme()`)
- **Light / Dark**: forces the corresponding color scheme

All views use SwiftUI semantic colors (`.primary`, `.secondary`, `.tertiary`, `Color.accentColor`), materials, and Liquid Glass (`.glassEffect(.regular)`). No custom color definitions exist.

## Spatial Hierarchy

The UI follows a three-plane model:

| Plane | Material | Use |
|-------|----------|-----|
| **Base** | Solid/opaque (`.quinary` + `.separator` stroke via `CardStyle`) | Content cards, email body, settings cards |
| **Navigation** | `.glassEffect(.regular)` | Category tabs, bulk action bars, smart reply chips |
| **Transient** | `.glassEffect(.regular)` + `.elevation(.transient)` via `floatingPanelStyle()` | Toasts, popovers, slide panels |

## Files

| File | Role |
|------|------|
| `AppearanceManager.swift` | Preference storage, UserDefaults persistence, migration from legacy theme system |
| `DesignTokens.swift` | Centralized design tokens and shared view modifiers (see below) |

## Design Tokens (`DesignTokens.swift`)

| Token | Values |
|-------|--------|
| `Spacing` | `xs` (4), `sm` (8), `md` (12), `lg` (16), `xl` (24), `xxl` (32), `xxxl` (48) |
| `CornerRadius` | `xs` (4), `sm` (6), `md` (12), `lg` (16), `xl` (24) |
| `ButtonSize` | `sm` (26), `md` (28), `lg` (30) |
| `SerifAnimation` | `springDefault`, `springSnappy`, `springGentle` |
| `Typography` | `titleLarge`, `title`, `titleSemibold`, `headline`, `headlineSemibold`, `subhead`, `subheadRegular`, `subheadSemibold`, `body`, `bodyMedium`, `bodySemibold`, `callout`, `calloutMedium`, `calloutSemibold`, `footnote`, `footnoteMedium`, `caption`, `captionRegular`, `captionSemibold`, `captionSmall`, `captionSmallMedium`, `captionSmallRegular`, `microTag` |

**View modifiers:**

| Modifier | Effect |
|----------|--------|
| `.elevation(.navigation / .transient / .elevated)` | Shadow scale (tight → wide) for spatial depth |
| `.selectableRowStyle(isSelected:isHovered:)` | Tint/primary/secondary foreground based on state |
| `.floatingPanelStyle()` | Liquid Glass + transient elevation for floating surfaces |
| `.glassOrMaterial(in:interactive:)` | Liquid Glass on macOS 26+ with `.regularMaterial` fallback |
| `.transientGlass()` | Glass + transient elevation for toast cards (macOS 26+ / material fallback) |
| `.destructiveActionStyle()` | Red text on red 10% opacity background in rounded rect — for destructive folder actions |

**Shared components** (also in `DesignTokens.swift`):

| Component | Purpose |
|-----------|---------|
| `ToolbarIconButton` | Standardised icon button with optional `.glass` or `.plain` style, `help` tooltip, and `ButtonSize` token |

## Migration

`AppearanceManager.init()` detects the old `selectedThemeId` UserDefaults key and maps it to Light or Dark based on the theme's name. The old keys (`selectedThemeId`, `themeOverrides`) are removed after migration.

## Settings UI

`ThemePickerView` provides a segmented picker (System / Light / Dark) inside the Settings panel.
