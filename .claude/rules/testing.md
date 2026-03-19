---
paths:
  - "VikTests/**/*.swift"
---

# Testing Conventions (Vik) — Supplements

Core testing patterns (Swift Testing, `@Test`, `#expect`, parameterized tests) are in `_code-style.md`.
This rule covers additional conventions specific to the test target.

## Database Tests
- Use in-memory `MailDatabase(accountID:baseDirectory:)` with temporary directories
- `BackgroundSyncer` tests create their own actor instance with the test database
- See `VikTests/Database/TestHelpers.swift` for shared fixtures and utilities
