# Appearance

System-integrated appearance management — follows macOS light/dark mode with optional user override.

## How It Works

`AppearanceManager` is an `@Observable` class that stores a single preference: System, Light, or Dark. It is owned by `ContentView` via `@State` and applied with `.preferredColorScheme()`.

- **System** (default): defers to macOS appearance (passes `nil` to `.preferredColorScheme()`)
- **Light / Dark**: forces the corresponding color scheme

All views use SwiftUI semantic colors (`.primary`, `.secondary`, `.tertiary`, `Color.accentColor`) and materials (`.regularMaterial`). No custom color definitions exist.

## Files

| File | Role |
|------|------|
| `AppearanceManager.swift` | Preference storage, UserDefaults persistence, migration from legacy theme system |

## Migration

`AppearanceManager.init()` detects the old `selectedThemeId` UserDefaults key and maps it to Light or Dark based on the theme's name. The old keys (`selectedThemeId`, `themeOverrides`) are removed after migration.

## Settings UI

`ThemePickerView` provides a segmented picker (System / Light / Dark) inside the Settings panel.
