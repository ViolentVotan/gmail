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
| `Constants.swift` | Shared constants: `GmailSystemLabel` enum. `UserDefaultsKey` enum has 9 static keys (`undoDuration`, `isSignedIn`, `notificationsEnabled`, `aiLabelSuggestions`, `showDebugMenu`, `syncDirectoryContacts`, `dismissedLabelSuggestions`) and 3 static functions (`signatureForNew(_:)`, `signatureForReply(_:)`, `attachmentExclusionRules(_:)`) that take an account ID. |
| `DateFormatting.swift` | Date display helpers (relative time, formatted dates). `timeFormatter` uses `.timeStyle = .short` (locale-aware — respects 12/24h setting). |
| `FileUtils.swift` | File system helpers (temp dirs, file size formatting). `saveWithPanel(data:suggestedName:)` presents an `NSSavePanel` for user-chosen save location. `imageExtensions` is a canonical `Set<String>` of supported image types (jpg, jpeg, png, gif, webp, heic, tiff, bmp). |
| `GmailDataTransformer.swift` | Transforms raw Gmail data (MIME parsing, header extraction, deterministic UUID). `parseContactCore` is a nonisolated static method (pure parsing without avatar resolution, safe from any isolation context). `parseContact` is `@MainActor` and delegates to `parseContactCore`. `makeEmail(from:isDraft:draftID:labels:)` is a `@MainActor` factory that constructs a full `Email` from a `GmailMessage`. `folderFor(labelIDs:)` priority order: draft → spam → trash → sent → inbox → starred → `.inbox` default. All label checks use `GmailSystemLabel` constants. |
| `HTMLTemplate.swift` | HTML email rendering templates with input sanitization (case-insensitive stripping of `<script>`, `<iframe>`, `<object>`, event handlers, `javascript:` URLs via multi-line regex with `[\\s\\S]*?`) and nonce-based Content-Security-Policy (`style-src 'unsafe-inline'`) |
| `InlineImageProcessor.swift` | Extracts inline data: images from HTML, converts to CID attachments. Uses a pre-compiled static `inlineImageRegex`. `InlineImageAttachment` conforms to `Sendable`. |
| `AIServiceHelpers.swift` | Shared helpers for AI services: `cacheKey(for:)`, `localeInstructions(for:)`, `cleanedPreview(from:)` |
| `PerAccountFileStore.swift` | Generic `@Observable @MainActor` per-account JSON file persistence. `PerAccountFileStore<Item>` stores items keyed by `accountID`. Key methods: `load(accountID:)` (replace), `loadMerging(accountID:)` (deduplicated merge), `save(accountID:)`, `deleteAccount(_:)`, `append(_:accountID:)`, `removeAll(accountID:where:)`, `replaceItems(_:accountID:)`. Supports an optional `legacyDecoder` closure for migrating old wrapper formats. |
| `StringExtensions.swift` | String/Data helpers: HTML stripping, `cleanedForAI`, `stableHash`, `Data(base64URLEncoded:)`, `htmlEscaped` (escapes `&`, `<`, `>`, `"`) |
