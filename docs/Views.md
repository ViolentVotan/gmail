# Views

SwiftUI views. UI presentation only — no business logic.

## Guidelines

- **No business logic in views.** Views read state from ViewModels and call callbacks. They do not:
  - Call Services or APIs directly
  - Perform data transformations beyond simple formatting
  - Contain persistence logic
- **No hardcoded colors.** Use SwiftUI semantic colors (`.primary`, `.secondary`, `.tertiary`, `Color.accentColor`) and materials (`.regularMaterial`, `.ultraThinMaterial`).
- **Callbacks over direct ViewModel access.** Views receive `onDelete`, `onArchive`, etc. as closures. Only top-level views (ContentView) wire these to ViewModels.
- **Small, composable views.** Extract reusable components into `Common/`. One concern per file.
- **Animations belong in views**, not in ViewModels or Services.
- **Property wrappers**: `@State` for owning `@Observable` objects (not `@StateObject`). `@Bindable` for write access to bindings on `@Observable` objects (not `@ObservedObject`). `@Environment` with `@Entry` macro for custom environment keys.
- **onChange syntax**: use `onChange(of:) { oldValue, newValue in }` (two-parameter closure).

## Subfolders

### `Sidebar/`
Left column — folder navigation, account switcher, labels. Context menu for label rename/delete.

### `EmailList/`
Middle column — email rows, swipe actions (archive/delete), search, pull-to-refresh, multi-select with bulk actions.

### `EmailDetail/`
Right column — thread view, HTML rendering (`HTMLEmailView` via WKWebView), attachments, sender info popover, tracker blocking UI, label picker.
- `ReplyBarView` — Inline quick reply with To/Cc/Bcc fields, draft persistence, auto-save, and discard confirmation.
- `DetailPaneView` — Contextual empty state (icon + message per folder).

### `Compose/`
Email composer — `ComposeView` for the full compose form with rich text editor, send-as alias picker, signature management, attachment list, and discard confirmation.
- `AutocompleteTextField` — Contact suggestions in To/Cc/Bcc fields.
- `WebRichTextEditor` — Web-based HTML editor with formatting toolbar.
- `FormattingToolbar` — Bold, italic, underline, font size, color, lists, headings, links.

### `Attachments/`
Attachment explorer with grid view, thumbnails, file type filtering, and search.

### `Onboarding/`
Sign-in / welcome screen with OAuth flow.

### `Common/`
Shared reusable components:
| File | Role |
|------|------|
| `AvatarView` | Circular avatar with initials fallback or profile image |
| `SearchBarView` | Search input with clear button |
| `LabelChipView` | Colored label pill |
| `ThemePickerView` | Segmented picker for System / Light / Dark appearance |
| `SettingsCardsView` | Settings UI with behavior, signature, account cards |
| `SlidePanel` | Animated side panel overlay (settings, help, debug, previews) with frosted glass background |
| `FormattingToolbar` | Rich text toolbar for compose/reply |
| `WebRichTextEditor` | WKWebView-based HTML editor |
| `UndoToastView` | Undo toast + offline indicator |
| `DebugMenuView` | API logs, cache controls |
| `ShortcutsHelpView` | Keyboard shortcuts reference |
| `AccountsSettingsView` | Account management settings |
