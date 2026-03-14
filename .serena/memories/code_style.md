# Code Style — Serif (Swift 6.2 / SwiftUI / macOS 26)

Target: macOS 26+, Xcode 26.3. SWIFT_VERSION = 6.2 (Swift 6.2 language mode). All Swift 6.2 concurrency features fully adopted: `@Observable`, typed throws (`throws(GmailAPIError)`), `@concurrent`, approachable concurrency with explicit `@MainActor` on VMs/services and `@concurrent` on I/O-bound service methods.

## Formatting
- 4-space indentation (no tabs)
- Trailing closures used consistently
- `// MARK: - Section` for code organization in large files
- `///` for doc comments (not `/** */`)
- Minimal inline comments — code should be self-documenting
- Imports grouped by domain (SwiftUI first, then system frameworks); access-level imports (`private import`) for implementation-detail dependencies

## Naming
- Files: match primary type name (`MailboxViewModel.swift`, `EmailPrintService.swift`)
- Types: PascalCase (`Email`, `GmailMessage`, `MailboxViewModel`)
- Functions: camelCase, action verbs (`loadFolder`, `markAsRead`, `toggleStar`)
- Variables: camelCase, descriptive (`selectedAccountID`, `isLoading`, `nextPageToken`)
- Enum cases: lowercase (`all`, `primary`, `social`)

## Access Control
- `private` by default for implementation details
- No explicit `public` or `internal` (single-target app)

## Types
- **Structs** for models: `Sendable` + `Identifiable` baseline; `Codable`, `Equatable`, `Hashable` as needed
- **`final class`** for all services and ViewModels (prevent subclassing)
- Protocol conformance inline (not in separate extensions)
- Extensions for domain-specific utilities (`String`, `Date`, `Font`)

## Architecture (MVVM)
- **Services**: Singletons via `static let shared` + `private init()`. `@MainActor` when touching UI state; `@concurrent` on I/O-bound methods. Dependency injection via initializer params for testability.
- **ViewModels**: `@Observable @MainActor final class` — 13 VMs follow this pattern (incl. `MailStore`, `SyncProgressManager`, `FiltersViewModel`). No `@Published`, no `ObservableObject`. Properties are plain `var` tracked by `@Observable` macro.
- **Views**: Pure SwiftUI rendering. No business logic. Access data via ViewModels only.
- **Models**: Value types (struct). Never reference services.
- **Exception**: `WebRichTextEditorState` stays as `ObservableObject` with `@Published` + `import Combine` — NSViewRepresentable bridge requirement.

## SwiftUI Patterns
- **`@Observable`** macro on all 13 VMs (incl. `MailStore`, `SyncProgressManager`), `AppearanceManager`, and services (`OfflineActionQueue`, `SubscriptionsStore`, `SnoozeMonitor`, `ToastManager`, `UndoActionManager`, `ScheduledSendStore`, `SnoozeStore`, `APILogger`, `ThumbnailCache`, `NetworkMonitor`)
- **`@State`** for ViewModel ownership in views (not `@StateObject`)
- **`@Bindable`** for child views needing two-way bindings to `@Observable` objects
- **Theming**: `AppearanceManager` (`@Observable @MainActor final class`) owns light/dark preference; `DesignTokens.swift` provides static enums (`Spacing`, `ButtonSize`, `CornerRadius`, `SerifAnimation`, `Typography`) and view modifiers (`elevation`, `destructiveActionStyle`, `floatingPanelStyle`, `glassOrMaterial`). Use standard `@Environment(\.colorScheme)` for light/dark — there is no custom theme environment key.
- **`@StateObject`** only for `WebRichTextEditorState` (3 usages — the sole `ObservableObject`)
- No `@EnvironmentObject` anywhere — fully migrated away
- `@State` for local view state, `@Binding` for parent-child communication
- `.task { }` for async loading (auto-cancels on disappear)
- `#Preview { }` macro for previews (not `PreviewProvider`)
- `containerRelativeFrame` for proportional sizing (prefer over `GeometryReader` for simple layouts)

## Concurrency
- `@MainActor` on all ViewModels and UI-touching services (explicit, not via `defaultIsolation`)
- `@concurrent` on service methods that do network I/O (Gmail API calls, OAuth token refresh)
- Typed throws: `throws(GmailAPIError)` on all Gmail service methods for precise error handling
- `async/await` throughout (no completion handlers)
- Prefer structured concurrency: `async let` for fixed concurrent work, `TaskGroup`/`withThrowingTaskGroup` for dynamic parallel tasks
- `Task { }` only for bridging sync → async (button actions, `.onAppear`); document why if unstructured
- Avoid `@unchecked Sendable` — restructure to use actors or value types instead

## Error Handling
- Typed throws (`throws(GmailAPIError)`) for Gmail API layer — callers get exhaustive error handling
- `do/catch` for operations that need error recovery
- `try?` when error details don't matter (fire-and-forget API calls)
- No `Result` type (async/await handles it)

## Control Flow
- `guard` for early returns (defensive programming)
- `if let` for optional binding in assignments
- `guard` heavily favored over `if let` for clarity
- Expression-style `if`/`switch` for assignments where it improves readability

## Testing
- All test files use **Swift Testing** (`import Testing`, `@Test`, `#expect`)
- No XCTest — fully migrated to Swift Testing framework
- Parameterized tests via `@Test(arguments:)` for data-driven testing

## UI Patterns
- Optimistic UI: mutate state immediately, then call API
- Consistent spring animation: `.spring(response: 0.38, dampingFraction: 0.82)`
- Multi-account: all persistence keyed by `accountID`
- Cache-first: load from disk, then refresh from API
- Pass specific values to child views (not whole objects) to minimize re-renders

## Database (GRDB 7.10.0)

### DatabasePool & Configuration
- `MailDatabase` is a `final class: Sendable` (not `@Observable`, not an actor) owning a `DatabasePool`
- Per-account SQLite file: `{accountID}.sqlite` in Application Support
- WAL mode via `PRAGMA journal_mode = WAL`, `PRAGMA synchronous = NORMAL`, `PRAGMA foreign_keys = ON`, `PRAGMA cache_size = -64000`

### Records
- Pattern: `struct FooRecord: Codable, Identifiable, FetchableRecord, PersistableRecord` (omit `Identifiable` for join tables like `MessageLabelRecord` and single-row tables like `AccountSyncStateRecord`)
- Column strategy on every record: `static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase` / `.convertToSnakeCase` — Swift camelCase properties map to snake_case columns
- 7 record types: `MessageRecord`, `LabelRecord`, `MessageLabelRecord`, `AttachmentRecord`, `EmailTagRecord`, `ContactRecord`, `AccountSyncStateRecord`
- `databaseTableName` is set explicitly on every record (e.g. `"messages"`, `"labels"`, `"message_labels"`)

### Associations
- Use GRDB association macros: `hasMany`, `hasOne`, `belongsTo` with explicit `ForeignKey([...])` — not inferred
- Through associations for many-to-many: `hasMany(LabelRecord.self, through: messageLabels, using: MessageLabelRecord.label)`
- Associations defined in extensions marked `// MARK: - GRDB Associations`

### Migrations
- `MailDatabaseMigrations` is a case-less enum with `static var migrator: DatabaseMigrator`
- `#if DEBUG migrator.eraseDatabaseOnSchemaChange = true #endif` for dev convenience
- Each migration is a private static method (e.g. `registerV1`) called from the migrator property
- Schema uses explicit column types (`.text`, `.integer`, `.boolean`, `.double`), `notNull()`, `defaults(to:)`, and explicit indexes
- Foreign keys declared inline: `.references("messages", column: "gmail_id", onDelete: .cascade)`
- Single-row tables use `primaryKey("id", .integer).check { $0 == 1 }` pattern (`AccountSyncStateRecord`)

### FTS5
- Manual FTS5 virtual table (`messages_fts`) — not using GRDB's `synchronize(withTable:)` content-sync
- Tokenizer: `porter unicode61`
- Manually maintained via `FTSManager` enum (index, update, delete, evictBody, indexBatch, search)
- `gmail_id` column marked `UNINDEXED` (used for joining, not searching)

### Concurrency & Writes
- `BackgroundSyncer` is an **actor** (not a class) for bulk database writes during sync (upsert messages, labels, contacts, delta sync)
- Lightweight writes (star, read, archive) go directly through `dbPool.write` — no actor needed
- `ValueObservation` in `MailboxViewModel` for reactive UI — observes DB changes, SwiftUI re-renders automatically
- Use `dbPool.read` for reads; `dbPool.write` for writes — never hold database connections across `await`

## Performance
- Use `LazyVStack`/`LazyHStack` in `ScrollView` for large collections
- `.task { }` over `.onAppear` for async work (auto-cancellation)
- Keep `body` pure and fast — move sorting/filtering into ViewModel
- Flat view hierarchies over deeply nested stacks
- Stable, unique identifiers in `ForEach` — avoid `id: \.self` on mutable collections
