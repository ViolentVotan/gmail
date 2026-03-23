# Appearance & Design Tokens

System-integrated appearance management and centralized design token system following Apple's macOS 26 Liquid Glass spatial hierarchy. For the full design language specification (glass rules, animation vocabulary, component specs, end-to-end flows), see [design-concept.md](design-concept.md).

## How It Works

`AppearanceManager` is an `@Observable` class that stores a single preference: System, Light, or Dark. It is owned by `VikApp` via `@State` and passed to both `ContentView` and `SettingsView`, then applied with `.preferredColorScheme()`.

- **System** (default): defers to macOS appearance (passes `nil` to `.preferredColorScheme()`)
- **Light / Dark**: forces the corresponding color scheme

All views use SwiftUI semantic colors (`.primary`, `.secondary`, `.tertiary`, `Color.accentColor`), materials, and Liquid Glass (`.glassEffect(.regular)`). `BrandColor.blueText` is the adaptive blue for text/icon foreground (meets 4.5:1 contrast in both light and dark); `BrandColor.blue` is reserved for backgrounds/fills. The `AccentColor` asset catalog entry provides four appearance-specific variants (light, dark, high-contrast light, high-contrast dark) for proper Liquid Glass adaptivity per Apple HIG. Data-driven colors (Gmail API labels, avatar hex colors) are contrast-checked at runtime via utilities in `Color+Contrast.swift` (see `docs/Utilities.md`). `LabelChipView` uses `label.textColor` for foreground, falling back to `.primary` when empty.

## Spatial Hierarchy

The UI follows a three-plane model (see `docs/design-concept.md` for the full glass language specification):

| Plane | Material | Use |
|-------|----------|-----|
| **Base** | Solid/opaque (`.quinary` + `.separator` stroke) | Content cards, email body, settings cards |
| **Navigation** | `.glassEffect(.regular.interactive())` | Toolbar buttons, category tabs, sidebar items (selected/hovered), email row selection, search bar, calendar event cards, mini calendar, avatars, label pills, bulk action bars, thread message cards |
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
| `CornerRadius` | `xs` (4), `sm` (6), `md` (12), `lg` (16), `xl` (24) |
| `ButtonSize` | `sm` (26), `md` (28), `lg` (30) |
| `VikAnimation` | `springDefault` (0.35/0.82), `springSnappy` (0.28/0.78), `springGentle` (0.4/0.88), `contentSwitch` (smooth 0.25), `folderSwitch` (smooth 0.3), `microBounce` (0.25/bounce 0.35) |
| `OpacityToken` | `disabled` (0.5), `subtle` (0.6), `secondary` (0.7), `highlight` (0.08), `tag` (0.12), `interactive` (0.15), `divider` (0.5), `overlay` (0.45) |
| `ScaleToken` | `hover` (1.03), `rowHover` (1.01), `press` (0.97), `emphasis` (1.04), `minimize` (0.5), `enterFrom` (0.95) |
| `OffsetToken` | `nudge` (4), `small` (12), `medium` (24), `large` (40) |
| `DurationToken` | `micro` (0.12), `quick` (0.2), `standard` (0.25), `deliberate` (0.3), `stagger` (0.04), `slow` (0.5) |
| `Typography` | `titleLarge`, `title`, `headline`, `subhead`, `subheadRegular`, `subheadSemibold`, `subheadMonospaced`, `body`, `bodyMedium`, `bodySemibold`, `callout`, `calloutMedium`, `calloutSemibold`, `footnote`, `caption`, `captionRegular`, `captionSemibold`, `captionMonospaced`, `captionSemiboldMonospaced`, `captionSmall`, `captionSmallMedium`, `captionSmallRegular`, `captionSmallMediumMonospaced`, `captionSmallBold`, `microTag` |

**Calendar tokens** (also in `DesignTokens.swift`):

| Token | Values |
|-------|--------|
| `CalendarColor` | 11 Google Calendar event colors: Lavender, Sage, Grape, Flamingo, Banana, Tangerine, Peacock, Blueberry, Basil, Tomato, and the default Graphite. Each case has adaptive `light` and `dark` `Color` properties for correct appearance in both modes. `static func color(forId colorId: Int?) -> Color` maps a Google API color ID to the SwiftUI color. `contrastingForeground(forId:)` returns `.white` or `.black` based on background luminance for WCAG-compliant text contrast. `name(forId:)` provides human-readable color names for accessibility labels. |
| `CalendarLayout` | `hourRowHeight` (48), `timeColumnWidth` (50), `eventCardMinHeight` (24), `eventCardBorderWidth` (3), `currentTimeIndicatorHeight` (2), `currentTimeIndicatorDotSize` (8), `allDayEventHeight` (22), `miniMonthDaySize` (20), `miniAgendaMaxEvents` (5), `monthViewMaxEventsPerCell` (3), `monthEventChipHeight` (18), `monthSpanningBarHeight` (20), `monthMaxSpanningRows` (3). Used by `CalendarWeekView`, `CalendarDayView`, `CalendarMonthView`, and `CalendarEventCard` to ensure pixel-consistent layout across views. |
| `CalendarSemanticColor` | `currentTimeIndicator` (`BrandColor.coral`), `todayHighlight` (brand blue at 3% opacity background tint in day/month columns), `todayHeaderCircle` (brand blue filled circle behind today's date number in headers), `eventCardBackgroundOpacity` (0.15 — applied to the event color for the glass card fill), `weekendColumnOpacity` (0.55 — Saturday/Sunday columns are dimmed relative to weekdays), `monthCellHover` (brand blue at 10% opacity for day cell hover highlight), `monthOverflowDayOpacity` (0.35 — reduced opacity for prev/next month overflow days; takes precedence over weekend dimming). |

**View modifiers:**

| Modifier | Effect |
|----------|--------|
| `.elevation(.surface / .raised / .transient / .elevated)` | 4-level shadow scale for spatial depth |
| `.floatingPanelStyle(cornerRadius:)` | Liquid Glass + transient elevation for floating surfaces (default `CornerRadius.md`) |
| `.dropdownPanelStyle()` | Glass + separator border overlay + dual shadow for dropdown/popover panels |
| `.glassOrMaterial(in:interactive:)` | Liquid Glass effect with optional interactive press feedback |
| `.destructiveActionStyle()` | Red text on red 10% opacity background in rounded rect — for destructive folder actions |

**Shared components** (also in `DesignTokens.swift`):

| Component | Purpose |
|-----------|---------|
| `ToolbarIconButton` | Standardised icon button with optional `.glass` or `.plain` style, `help` tooltip, and `ButtonSize` token |

## Migration

`AppearanceManager.init()` detects the old `selectedThemeId` UserDefaults key and maps it to Light or Dark based on the theme's name. The old keys (`selectedThemeId`, `themeOverrides`) are removed after migration.

## Settings UI

`ThemePickerView` provides a segmented picker (System / Light / Dark) inside the Settings panel.
