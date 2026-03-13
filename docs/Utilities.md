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
| `Constants.swift` | Shared constants: `UserDefaultsKey` enum, `GmailSystemLabel` enum |
| `DateFormatting.swift` | Date display helpers (relative time, formatted dates) |
| `FileUtils.swift` | File system helpers (temp dirs, file size formatting) |
| `GmailDataTransformer.swift` | Transforms raw Gmail data (MIME parsing, header extraction, deterministic UUID) |
| `HTMLTemplate.swift` | HTML email rendering templates with input sanitization (strips `<script>`, `<iframe>`, event handlers, `javascript:` URLs) and Content-Security-Policy |
| `InlineImageProcessor.swift` | Extracts inline data: images from HTML, converts to CID attachments |
| `AIServiceHelpers.swift` | Shared helpers for AI services: `cacheKey(for:)`, `localeInstructions(for:)`, `cleanedPreview(from:)` |
| `StringExtensions.swift` | String/Data helpers: HTML stripping, `cleanedForAI`, `stableHash`, `Data(base64URLEncoded:)` |
