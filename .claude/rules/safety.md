---
paths:
  - "**/*.swift"
  - "**/*.yml"
  - "**/*.yaml"
  - "**/*.sh"
  - "**/*.plist"
---

# Safety Rules (Vik)

- **NEVER** touch `Vik/Configuration/GoogleCredentials.swift` — gitignored, contains OAuth secrets
- **NEVER** modify `ExportOptions.plist` signing config without explicit approval
- **NEVER** alter the CI release pipeline (`.github/workflows/release.yml`) without discussing impact
- **ALWAYS** verify builds compile before completing a task (`xcodebuild -scheme Vik -configuration Debug build`)
- **ALWAYS** run affected tests after changes to Services, ViewModels, or Database code
