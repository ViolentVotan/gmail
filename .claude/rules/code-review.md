---
paths:
  - "**/*.swift"
---

# Code Review Criteria — Vik (Weighted)

When reviewing Vik code (manually or via the `code-reviewer` agent), apply these **weighted criteria**. Higher weight = more scrutiny.

## Weights

| Dimension | Weight | Why |
|-----------|--------|-----|
| **Concurrency safety** | 5/5 | Swift 6.2 strict concurrency, actors, `@MainActor`/`@concurrent` boundaries, `Sendable` — data races are the #1 crash risk |
| **Wiring & reachability** | 5/5 | MVVM + 7 sub-coordinators = high risk of orphaned code. Verify new code is actually called through coordinator chains |
| **Actor isolation** | 4/5 | `BackgroundSyncer`/`CalendarBackgroundSyncer` actors, `@MainActor` VMs — cross-isolation calls must be correct |
| **GRDB patterns** | 4/5 | `dbPool.write` never across `await`, WAL mode, `ValueObservation` reactivity, migration safety |
| **UI correctness** | 3/5 | Design tokens (`Spacing`, `Typography`, `VikAnimation`), glass rules, accessibility labels, reduced motion |
| **Multi-account** | 3/5 | All persistence keyed by `accountID`, per-account stores merge not replace |
| **Craft** | 2/5 | Naming, style, duplication — `_code-style.md` covers this; lower weight because conventions are well-established |

## Concurrency Red Flags (auto-CRITICAL)

- Accessing `@MainActor`-isolated state from `@concurrent` method without `await`
- `@unchecked Sendable` conformance (restructure to actors or value types)
- Holding database connection across `await` (`dbPool.write` with async inside)
- Missing `nonisolated` on computed properties accessed cross-isolation
- `Task { }` without comment explaining why unstructured concurrency is needed

## Wiring Red Flags (auto-WARNING)

- New ViewModel/service not registered in any coordinator
- New view not reachable from any navigation path
- New coordinator method not called from any view or parent coordinator
- Export/public method with zero callers (check with `find_referencing_symbols`)

## GRDB Red Flags (auto-WARNING)

- Raw SQL instead of query interface (unless FTS5 or complex join)
- Missing `ForeignKey([...])` in association (never rely on inference)
- Migration without explicit column types or missing `notNull()` where appropriate
- `dbPool.read` for write operations or vice versa
