# Vik Design Concept

Authoritative design reference for Vik — a premium native macOS 26 email and calendar client. Every UI/UX decision must conform to this document. When in doubt, this document overrides ad-hoc judgement.

## Design Philosophy

**One sentence:** Vik is a Liquid Glass instrument — every surface the user touches responds with translucent depth, spring-driven motion, and spatial continuity.

### Core Principles

1. **Glass is structure, not decoration.** Glass communicates interactivity. If an element is clickable and changes state, it has glass. If it's static content, it doesn't. Never apply glass for aesthetics alone.

2. **Motion encodes meaning.** Every animation answers "what just happened?" — a directional slide says navigation, a crossfade says replacement, a spring bounce says confirmation. No motion is decorative.

3. **Hierarchy through depth, not weight.** Use the three-plane spatial model (Base → Navigation → Transient) to separate content layers. Avoid relying on bold text or large sizes alone to create hierarchy — depth and translucency do the work.

4. **Restraint is premium.** Show less, mean more. One primary action per context. Contextual controls appear on demand. Empty space is a feature, not waste.

5. **Continuity across modes.** Switching between Mail and Calendar, between folders, between emails — shared elements persist, content crossfades directionally, nothing teleports. The user should never lose spatial orientation.

---

## Spatial Model

Three planes define every surface in the app:

| Plane | Treatment | Use | Examples |
|-------|-----------|-----|----------|
| **Base** | `.background(.quinary)` + `.separator` stroke | Static content containers | Email body cards, settings cards, compose editor |
| **Navigation** | `.glassEffect(.regular.interactive())` | Interactive controls, selection indicators | Category tabs, sidebar items, toolbar buttons, email row selection, calendar event cards, search bar |
| **Transient** | `.glassEffect(.regular)` + `.elevation(.transient)` | Floating surfaces that dismiss | Toasts, popovers, slide panels, dropdowns, command palette |

**Rule:** Navigation-plane elements always use `.interactive()` so they respond to hover/press with enhanced blur. Transient-plane elements use non-interactive glass — they're already visually prominent through elevation.

---

## Glass Language

### When to Apply Glass

| Element Type | Glass | Interactive | Shape |
|-------------|-------|-------------|-------|
| Sidebar folder/label (selected or hovered) | Yes | Yes | `.rect(cornerRadius: CornerRadius.sm)` |
| Category tab (selected or hovered) | Yes | Yes | `.capsule` |
| Email list row (selected) | Yes | Yes | `.rect(cornerRadius: CornerRadius.sm)` |
| Toolbar buttons | Yes | — | `.buttonStyle(.glass)` |
| Search bar | Yes | Yes | `.capsule` |
| Sync bubble | Yes | Yes | `.circle` (compact) / `.capsule` (expanded) |
| Calendar event cards | Yes | Yes | `.rect(cornerRadius: CornerRadius.sm)` |
| Mini calendar today/selected day | Yes | Yes | `.circle` |
| Calendar Day/Week/Agenda toggle | Yes | Yes | `.capsule` (matched geometry) |
| Account badge pills in email rows | Yes | No | `.capsule` |
| Toast notifications | Yes | No | `.rect(cornerRadius: CornerRadius.md)` |
| Reply bar (floating) | Yes | No | `.rect(cornerRadius: CornerRadius.md)` |
| Email body content area | No | — | Base-plane card with border |
| Static labels / text | No | — | — |
| Dividers | No | — | — |

### Glass Identity Rule

When an element has two states (e.g., selected vs. unselected), use `.identity` for the inactive state and `.regular.interactive()` for the active/hovered state:

```swift
.glassEffect(
    isSelected || isHovered ? .regular.interactive() : .identity,
    in: .capsule
)
```

This makes inactive elements invisible as glass surfaces and active ones glow with translucent depth.

---

## Animation Vocabulary

### Spring Tiers

Every animation in Vik uses one of three springs. No other timing curves (except `.smooth` for content crossfades).

| Spring | Token | Response | Damping | Use |
|--------|-------|----------|---------|-----|
| **Default** | `VikAnimation.springDefault` | 0.35 | 0.82 | Sidebar toggle, toasts, modals, panel slides |
| **Snappy** | `VikAnimation.springSnappy` | 0.28 | 0.78 | Tab switches, hover feedback, toggles, row selection |
| **Gentle** | `VikAnimation.springGentle` | 0.4 | 0.88 | Onboarding sequences, deliberate reveals |

### Content Transitions

| Transition | Token | Duration | Use |
|-----------|-------|----------|-----|
| **Content switch** | `VikAnimation.contentSwitch` | smooth 0.25s | Email-to-email swap, category list reload |
| **Folder switch** | `VikAnimation.folderSwitch` | smooth 0.3s | Folder change, account switch, mail↔calendar |
| **Micro bounce** | `VikAnimation.microBounce` | 0.25s / bounce 0.35 | Star toggle, read/unread, small confirmations |

### Motion Patterns

#### Directional Navigation
When the user moves forward/deeper, content enters from below. When moving backward/up, content enters from above. This applies to:
- Email selection (next email enters from bottom, previous from top)
- Folder/category switching (new list enters based on list position)
- Mail↔Calendar mode switch (horizontal: mail slides left, calendar slides in from right)

**Offset distance:** `OffsetToken.small` (12pt) for email navigation within a list, `OffsetToken.medium` (24pt) for major context switches (folder, mode).

#### Staggered Entrance
When a list of items appears (email rows after folder switch, label suggestions):
- Each item delays by `DurationToken.stagger` (40ms)
- Maximum 10 items stagger; the rest appear with the 10th
- Animation: opacity 0→1 + y-offset `OffsetToken.nudge` (4pt) → 0
- Spring: `VikAnimation.springSnappy`

#### Crossfade Replacement
When content is replaced in-place (email body swap, mode switch):
- Outgoing content fades out (150ms, ease-in)
- Incoming content fades in with slight y-offset (250ms, spring)
- Use `.contentTransition(.opacity)` on the container

#### Scale Feedback
Interactive elements respond to hover/press with scale:
- **Hover:** `ScaleToken.hover` (1.03) for cards, `ScaleToken.rowHover` (1.01) for list rows
- **Press:** `ScaleToken.press` (0.97) — brief spring-back
- Calendar event cards use hover scale + dynamic shadow increase

#### Symbol Effects
SF Symbols use built-in effects for micro-feedback:
- `.symbolEffect(.bounce)` — star toggle, action confirmation
- `.symbolEffect(.breathe)` — idle/waiting states (sync bubble)
- `.symbolEffect(.pulse)` — error/attention states
- `.contentTransition(.symbolEffect(.replace))` — icon swap (sync states)

### Matched Geometry

Use `matchedGeometryEffect` for elements that visually persist across state changes:
- **Category tab selection indicator** — capsule slides between tabs
- **Command palette** — scales from trigger point
- **Reply bar** — compose field expansion

### Interruptibility

All animations must be interruptible. If the user clicks rapidly through emails or tabs, each new animation cancels the previous. SwiftUI springs handle this natively. Avoid `.animation` modifiers on containers that could queue up conflicting transitions — prefer `withAnimation` on the state change instead.

---

## End-to-End Flows

### Email Selection

1. User clicks email row in list
2. Row receives glass highlight (`.glassEffect(.regular.interactive())`) with `springSnappy`
3. Previous email detail fades out (opacity → 0, 150ms)
4. New email detail fades in with directional y-offset (`OffsetToken.small`, based on whether navigating up or down the list)
5. Scroll position resets to top with animation
6. HTML body shows skeleton shimmer while loading, then crossfades to rendered content (`VikAnimation.contentSwitch`)
7. Label suggestions stagger in (40ms per label)

### Folder / Category Switch

1. User clicks folder or category tab
2. Category tab: matched geometry capsule slides to new position (`springSnappy`)
3. Current email list fades out with upward offset (8pt, 150ms)
4. New email list rows stagger in (40ms per row, opacity + 4pt y-offset, `springSnappy`)
5. If a previously-selected email still exists in the new list, detail pane stays. Otherwise, detail pane shows empty state or first email with crossfade.

### Mail ↔ Calendar Mode Switch

1. User clicks mode toggle in sidebar
2. Toggle capsule slides to new position (matched geometry, `springSnappy`)
3. Sidebar content crossfades: folder list ↔ mini calendar (`VikAnimation.folderSwitch`)
4. Main content area transitions horizontally:
   - Mail→Calendar: mail slides left + fades, calendar slides in from right
   - Calendar→Mail: calendar slides right + fades, mail slides in from left
5. Toolbar and window title remain stable — no flicker

### Thread Message Expand/Collapse

1. User clicks collapsed thread message
2. Card height expands with `springDefault`
3. Content fades in during expansion (opacity + slight offset)
4. Expanded card uses glass background if hovered

### Compose / Reply

1. User clicks reply bar or compose button
2. Reply bar expands with `springSnappy`
3. Text field receives focus with subtle glow intensification
4. CC/BCC fields reveal with height animation when toggled
5. On send: reply bar collapses, success toast slides up from bottom

---

## Component Specifications

### Email Row

| Property | Spec |
|----------|------|
| Padding | Density-driven: compact 6pt, comfortable 10pt, spacious 14pt |
| Avatar | 30pt circle, glass backing (`.glassEffect(.regular, in: .circle)`) |
| Sender | `Typography.calloutSemibold` (bold when unread) |
| Subject | `Typography.callout` (regular weight) |
| Preview | `Typography.caption`, `.secondary` foreground, single line |
| Timestamp | `Typography.caption`, `.tertiary` foreground, right-aligned |
| Unread indicator | 8pt blue circle, leading edge |
| Selected state | Glass background (`.regular.interactive()`, `.rect(cornerRadius: CornerRadius.sm)`) |
| Hover state | Subtle glass highlight (`.identity` → `.regular.interactive()` transition) |
| Account badge | Glass capsule, `Typography.captionSmall` |

### Sidebar

| Property | Spec |
|----------|------|
| Expanded width | 240pt |
| Collapsed width | 64pt |
| Folder item height | 28pt |
| Selected state | Glass background (`.regular.interactive()`, `.rect(cornerRadius: CornerRadius.sm)`) with accent tint |
| Hover state | Glass highlight matching selected but without accent tint |
| Section headers | `Typography.captionSemibold`, `.secondary` foreground, `Spacing.lg` top margin |
| Unread count | `Typography.captionSemibold`, `.secondary` foreground, right-aligned |
| Mode toggle | Glass segmented control with icons (envelope + calendar), matched geometry selection |
| Collapse animation | `springDefault` width transition, text fades after width reaches target |

### Category Tab Bar

| Property | Spec |
|----------|------|
| Container | `GlassEffectContainer(spacing: 4)` |
| Tab shape | `.capsule` |
| Selected tab | Glass interactive + accent foreground + `matchedGeometryEffect` capsule |
| Unselected tab | `.identity` glass, `.secondary` foreground |
| Hover | Glass interactive, smooth transition |
| Overflow | Horizontally scrollable when tabs exceed available width |
| Animation | `springSnappy` for selection, `.snappy(duration: 0.2)` for hover |

### Toolbar

| Property | Spec |
|----------|------|
| Buttons | `ToolbarIconButton` with `useGlass: true` always |
| Compose button | Visually prominent: filled accent + glass, slightly larger (`ButtonSize.lg`) |
| Contextual actions | Reply/Archive/Delete/Snooze appear only when email is selected |
| Grouping | Logical groups separated by `ToolbarSpacer()`: Compose | Reply actions | Organize | Utility |
| Icon font | `Typography.body` (default), `Typography.callout` for secondary |

### Calendar Event Card

| Property | Spec |
|----------|------|
| Background | Glass (`.regular.interactive()`, `.rect(cornerRadius: CornerRadius.sm)`) with event color tint at `CalendarSemanticColor.eventCardBackgroundOpacity` |
| Left border | `CalendarLayout.eventCardBorderWidth` (3pt) in event color |
| Title | `Typography.captionSemibold`, primary foreground |
| Time | `Typography.captionSmall`, `.secondary` foreground |
| Hover | `ScaleToken.rowHover` (1.01) + increased shadow |
| Min height | `CalendarLayout.eventCardMinHeight` (24pt) |

### Mini Calendar

| Property | Spec |
|----------|------|
| Day cell size | `CalendarLayout.miniMonthDaySize` (20pt) |
| Today indicator | Glass circle (`.regular.interactive()`, `.circle`) with accent color fill |
| Selected day | Glass circle with accent border |
| Hover | Subtle glass circle |
| Navigation arrows | Standard system buttons with glass |

### Current-Time Indicator

| Property | Spec |
|----------|------|
| Line | `CalendarLayout.currentTimeIndicatorHeight` (2pt), `CalendarSemanticColor.currentTimeIndicator` (coral) |
| Dot | `CalendarLayout.currentTimeIndicatorDotSize` (8pt) circle at leading edge |
| Update | Every 60 seconds, smooth position animation |
| Z-order | Above event cards, below transient surfaces |

---

## Dark Mode

### Principles
- SwiftUI semantic colors (`.primary`, `.secondary`, `.tertiary`) handle most adaptation automatically
- Data-driven colors (avatars, labels, calendar events) use `Color.adaptive(light:dark:)` with desaturated dark variants
- Glass effects adapt natively — no manual dark mode adjustments needed for glass
- Email HTML content renders on white/light backgrounds — use a soft gradient vignette at content boundaries to blend with dark app chrome

### Avatar Colors in Dark Mode
- Reduce saturation by 15-20% compared to light mode
- Reduce brightness slightly to prevent avatars from being the loudest element
- Use `Color.adaptive()` for all avatar background colors

### Content Boundary Blending
- Where email HTML (white background) meets dark app chrome, apply a subtle gradient overlay at the top and bottom edges of the content area
- This prevents the harsh "hole in the dark" effect
- Gradient: from app background color (opacity 0.3) to transparent, height ~16pt

---

## Typography Hierarchy

### Email List
| Element | Token | Weight | Color |
|---------|-------|--------|-------|
| Sender (unread) | `Typography.calloutSemibold` | Semibold | `.primary` |
| Sender (read) | `Typography.callout` | Regular | `.primary` |
| Subject | `Typography.callout` | Regular | `.primary` |
| Preview | `Typography.caption` | Medium | `.secondary` |
| Timestamp | `Typography.caption` | Medium | `.tertiary` |
| Account badge | `Typography.captionSmall` | Semibold | Custom |
| Section header | `Typography.captionSemibold` | Semibold | `.secondary` |

### Email Detail
| Element | Token | Weight | Color |
|---------|-------|--------|-------|
| Subject | `Typography.titleLarge` | Bold | `.primary` |
| Sender name | `Typography.bodySemibold` | Semibold | `.primary` |
| Sender email | `Typography.caption` | Medium | `.secondary` |
| Timestamp | `Typography.caption` | Medium | `.tertiary` |
| Label pills | `Typography.captionSemibold` | Semibold | Custom |

### Calendar
| Element | Token | Weight | Color |
|---------|-------|--------|-------|
| Date range header | `Typography.title` | Bold | `.primary` |
| Day header | `Typography.subheadSemibold` | Semibold | `.primary` |
| Time labels | `Typography.caption` | Medium | `.tertiary` |
| Event title | `Typography.captionSemibold` | Semibold | `.primary` |
| Event time | `Typography.captionSmall` | Medium | `.secondary` |

---

## Accessibility

### Motion
- Respect `@Environment(\.accessibilityReduceMotion)` everywhere
- When reduced motion is active: replace springs with instant state changes, disable stagger delays, keep only opacity crossfades
- Never block UI interaction during animations

### Contrast
- All text meets WCAG AA (4.5:1 for body, 3:1 for large text)
- Glass surfaces have sufficient contrast against both light and dark backgrounds — test independently
- Focus rings: 2-4px visible outline on all interactive elements via keyboard navigation

### Dynamic Type
- Support system text scaling throughout
- Avoid fixed-size text containers that truncate as type grows
- Test at largest accessibility size

### Screen Reader
- All interactive elements have `.accessibilityLabel()` and `.help()` (macOS tooltip)
- Navigation structure uses accessibility rotors for folders, unread, starred, attachments
- State changes announced via `.accessibilityValue()` (selected, expanded, unread count)

---

## Anti-Patterns

Do not do these:

| Anti-Pattern | Why | Instead |
|-------------|-----|---------|
| Flat opaque selection highlights | Breaks glass language | Use `.glassEffect(.regular.interactive())` |
| Decorative animation without purpose | Feels gimmicky | Every animation encodes a state change |
| Mixing `.easeInOut` with springs | Inconsistent timing feel | Springs everywhere, `.smooth` for crossfades only |
| Glass on static text/labels | Dilutes the interactive signal | Glass = clickable |
| Instant content replacement | Loses spatial context | Always crossfade or directionally transition |
| Truncating category tabs | Feels unfinished | Scroll or abbreviate |
| White HTML on dark chrome without blending | Harsh visual hole | Gradient vignette at boundaries |
| Independent animation timings per view | Feels disconnected | Use `VikAnimation` tokens exclusively |
| Hover-only affordances | Inaccessible on trackpad | All hover states have a visible resting state equivalent |
| Multiple primary CTAs per context | Decision paralysis | One primary (compose), rest secondary |
