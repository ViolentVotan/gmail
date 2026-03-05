# Utilities

Pure helper functions and extensions. Zero state, zero side effects.

## Guidelines

- **Pure functions only**: input -> output. No singletons, no persistence, no network.
- No SwiftUI view code. No `@Published`, no `ObservableObject`.
- If a utility grows to need state or persistence, move it to `Services/` or `Models/`.
- Keep utilities small and focused. One file per concern.

## Files

| File | Role |
|------|------|
| `DateFormatting.swift` | Date display helpers (relative time, formatted dates) |
| `FileUtils.swift` | File system helpers (temp dirs, file size formatting) |
| `GmailDataTransformer.swift` | Transforms raw Gmail data (MIME parsing, header extraction, deterministic UUID) |
| `InlineImageProcessor.swift` | Extracts inline data: images from HTML, converts to CID attachments |
| `SignatureResolver.swift` | Signature HTML lookup per alias, signature replacement in body |
| `ComposeModeInitializer.swift` | Initializes compose fields based on mode (reply, forward, new) |
| `HTMLTemplate.swift` | HTML email rendering templates |
| `StringExtensions.swift` | String helpers (HTML stripping, truncation) |
| `URLExtensions.swift` | URL helpers (file type detection, SF Symbol icons, email compatibility) |
