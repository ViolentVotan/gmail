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
- **Respect reduced motion.** Check `@Environment(\.accessibilityReduceMotion)` before animating.
