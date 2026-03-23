---
paths:
  - "Vik/Views/**"
  - "Vik/Theme/**"
  - "Vik/ContentView.swift"
---

# Design Rules — Vik UI

Before making any UI change, read `docs/design-concept.md` — it is the authoritative design reference.

## Quick Rules

- **Glass = interactive.** If it's clickable and stateful, it gets `.glassEffect(.regular.interactive())`. Static content stays flat.
- **Springs only.** Use `VikAnimation` tokens (springDefault/springSnappy/springGentle) for all motion. `.smooth` only for content crossfades. No `.easeInOut`, `.linear`, or custom curves.
- **Directional transitions.** Forward/down = content enters from below. Backward/up = from above. Horizontal for mode switches.
- **Stagger lists.** New list items delay by `DurationToken.stagger` (40ms), max 10 items.
- **One primary CTA.** Compose is the primary action. Everything else is secondary.
- **Toolbar glass always.** `ToolbarIconButton(useGlass: true)` — no plain toolbar buttons.
- **Respect reduced motion.** Check `@Environment(\.accessibilityReduceMotion)` before animating. Pattern: `withAnimation(reduceMotion ? nil : VikAnimation.xxx)`.
- **Use design tokens.** No magic numbers for padding/spacing — use `Spacing.*` tokens. No raw `.font(.caption2)` — use `Typography.*`. No hardcoded `.zIndex()` — use `ZIndexToken.*`.
- **Adaptive text colors.** Use `BrandColor.blueText` (not `.blue`) for text/icon foreground — it meets 4.5:1 contrast in both light and dark mode.
- **Accessibility labels.** All icon-only buttons need `.accessibilityLabel()` — `.help()` tooltips alone are not read by VoiceOver.
- **Section headers.** Add `.accessibilityAddTraits(.isHeader)` to section header text for VoiceOver navigation.
