---
paths:
  - "Vik/Database/**/*.swift"
---

# GRDB Database Conventions (Vik) — Supplements

Core GRDB patterns (records, associations, migrations, FTS5, write patterns) are in `_code-style.md`.
This rule covers additional conventions specific to the database layer.

## Paths
- All persistence uses `AppPaths.appSupportDirectory` (defined in `Constants.swift`)
- Debug builds use `com.vikingz.vik.app-debug/`, Release uses `com.vikingz.vik.app/` — keeps development isolated from production data

## Queries (`MailDatabaseQueries`)
- Case-less enum with static methods taking `in db: Database` parameter
- Prefer GRDB query interface and associations over raw SQL
