# Utilities

Pure helper functions, extensions, and constants. Zero state, zero side effects.

## Guidelines

- **Pure functions only**: input -> output. No singletons, no persistence, no network.
- No SwiftUI view code. No `@Observable` classes — if a utility needs observable state, move it to `Services/` or `ViewModels/`.
- If a utility grows to need state or persistence, move it to `Services/` or `Models/`.
- Keep utilities small and focused. One file per concern.

## Files

| File | Role |
|------|------|
| `Color+Hex.swift` | SwiftUI `Color` extension: `hexString` property (Color → #RRGGBB), `init(hex:)` initializer (hex string → Color) |
| `Color+Contrast.swift` | WCAG 2.1 contrast utilities. `NSColor` extension: `relativeLuminance()`, `contrastRatio(against:)`, `adjustedForContrast(against:targetRatio:)`. `Color` convenience wrapper (sRGB-concrete colors only — not for semantic/catalog colors). `Color.contrastTarget(for:)` returns 4.5 (standard) or 7.0 (increased contrast). Used by `LabelChipView` and `AvatarView` for data-driven color safety. |
| `Constants.swift` | Shared constants: `GmailSystemLabel` enum. `UserDefaultsKey` enum has 9 static keys (`undoDuration`, `isSignedIn`, `notificationsEnabled`, `aiLabelSuggestions`, `showDebugMenu`, `syncDirectoryContacts`, `dismissedLabelSuggestions`) and 3 static functions (`signatureForNew(_:)`, `signatureForReply(_:)`, `attachmentExclusionRules(_:)`) that take an account ID. `NetworkConfig` enum provides `externalSession` (shared `URLSession` with 15s request / 30s resource timeouts for non-Gmail external requests). |
| `DateFormatting.swift` | Date display helpers (relative time, formatted dates). `shortDateFormatter` and `shortDateYearFormatter` use `setLocalizedDateFormatFromTemplate` for locale-aware month/day formatting. `timeFormatter` uses `.timeStyle = .short` (locale-aware — respects 12/24h setting). `gmailQueryFormatter` uses `en_US_POSIX` for machine-readable API dates. |
| `FileUtils.swift` | File system helpers (temp dirs, file size formatting). `saveWithPanel(data:suggestedName:)` presents an `NSSavePanel` for user-chosen save location. `imageExtensions` is a canonical `Set<String>` of supported image types (jpg, jpeg, png, gif, webp, heic, tiff, bmp). |
| `GmailDataTransformer.swift` | Transforms raw Gmail data (MIME parsing, header extraction, deterministic UUID). `parseContactCore` is a nonisolated static method (pure parsing without avatar resolution, safe from any isolation context). `parseContact` is `@MainActor` and delegates to `parseContactCore`. `makeEmail(from:isDraft:draftID:labels:)` is a `@MainActor` factory that constructs a full `Email` from a `GmailMessage`. `folderFor(labelIDs:)` priority order: draft → spam → trash → sent → inbox → starred → `.archive` default (archived Gmail messages have no INBOX label). All label checks use `GmailSystemLabel` constants. |
| `HTMLTemplate.swift` | HTML email rendering templates with CSS sanitization (`sanitizeCSSValue()` applied to all color interpolations) and HTML sanitization (case-insensitive stripping of `<script>`, `<style>`, `<iframe>`, `<object>`, `<embed>`, `<form>`, `<base>`, `<meta http-equiv>`, event handlers, `javascript:` URLs, `data:text/html` URIs via multi-line regex with `[\\s\\S]*?`) and nonce-based Content-Security-Policy (`style-src 'unsafe-inline'`) |
| `InlineImageProcessor.swift` | Extracts inline data: images from HTML, converts to CID attachments. Uses `NSMutableString`/`NSRange` for safe reverse-iteration replacement. Pre-compiled static `inlineImageRegex`. `InlineImageAttachment` conforms to `Sendable`. |
| `AIServiceHelpers.swift` | Shared helpers for AI services: `cacheKey(for:) -> String` (non-optional), `localeInstructions(for:)`, `cleanedPreview(from:)` |
| `LRUCache.swift` | Generic `@MainActor` LRU cache with O(1) get/set/evict via doubly-linked list + dictionary. Configurable max size and eviction fraction. Used by SmartReplyProvider, BIMIService, QuickReplyService, SummaryService, EmailClassifier, LabelSuggestionService. |
| `PerAccountFileStore.swift` | Generic `@Observable @MainActor` per-account JSON file persistence. `PerAccountFileStore<Item>` stores items keyed by `accountID`. Key methods: `load(accountID:)` (replace), `loadMerging(accountID:)` (deduplicated merge), `loadFiltered(by:keyPath:)` (load + prune items not matching account), `save(accountID:)`, `deleteAccount(_:)`, `append(_:accountID:)`, `removeAll(accountID:where:)`, `replaceItems(_:accountID:)`. Supports an optional `legacyDecoder` closure for migrating old wrapper formats. Uses `Logger` for error/warning logging on save/load failures. |
| `StringExtensions.swift` | String/Data helpers: HTML stripping, `cleanedForAI`, `stableHash`, `Data(base64URLEncoded:)` / `Data.base64URLEncodedString()` (symmetric base64url encode/decode), `String.withReplyPrefix` / `String.withForwardPrefix` (idempotent Re:/Fwd: prefixing), `htmlEscaped` (escapes `&`, `<`, `>`, `"`) |
