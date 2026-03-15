# Views

SwiftUI views. UI presentation only — no business logic.

## Guidelines

- **No business logic in views.** Views read state from ViewModels and call callbacks. They do not:
  - Call Services or APIs directly
  - Perform data transformations beyond simple formatting
  - Contain persistence logic
- **No hardcoded colors.** Use SwiftUI semantic colors (`.primary`, `.secondary`, `.tertiary`, `Color.accentColor`). Use `.cardStyle()` for Base-plane content cards, `.glassEffect(.regular)` for Navigation-plane surfaces, and `.floatingPanelStyle()` for Transient-plane overlays. Use `Spacing`, `CornerRadius`, `Typography`, and `SerifAnimation` tokens from `DesignTokens.swift`.
- **Action structs over individual closures.** Views receive callbacks via action structs (`EmailListActions`, `EmailDetailActions`) rather than dozens of individual closure parameters. Only top-level views (ListPaneView, DetailPaneView) construct these structs and wire them to ViewModels/coordinators.
- **Small, composable views.** Extract reusable components into `Common/`. One concern per file.
- **Animations belong in views**, not in ViewModels or Services.
- **Property wrappers**: `@State` for owning `@Observable` objects (not `@StateObject`). `@Bindable` for write access to bindings on `@Observable` objects (not `@ObservedObject`). `@Environment` with `@Entry` macro for custom environment keys.
- **onChange syntax**: use `onChange(of:) { oldValue, newValue in }` (two-parameter closure).
- **`WKNavigationDelegate` / `WKUIDelegate` coordinators** (`WebRichTextEditorCoordinator`, `SearchBarView.Coordinator`) are marked `final` — do not subclass them.
- **ContentView** routes quick-reply and attachment download through `AppCoordinator` (`handleQuickReply`, `downloadAttachment`) rather than handling them inline.

## Subfolders

### `Sidebar/`
Left column — `List(.sidebar)` with folder navigation, account switcher, labels. Context menu for label rename/delete. Gets Liquid Glass treatment automatically from NavigationSplitView. `SidebarView` and `AccountSwitcherView` accept `onSignOut` callback threaded from `ContentView`. `AccountSwitcherView` uses closure-based callbacks (`onSetAsDefault`, `onSetAccentColor`) wired from `SidebarView` — no direct `AccountStore` access.
- `SyncBubbleView` — Transient liquid glass sync status bubble (driven by `SyncProgressManager`).

### `EmailList/`
Middle column — email rows with native `.swipeActions()` (archive/delete), search, `.refreshable` pull-to-refresh, multi-select with bulk actions. Uses `List(selection:)` for row rendering. Date-based sort orders show section headers (Today, Yesterday, This Week, Last Week, month/year). Email rows merge Gmail labels and AI classification tags into a single capped badge row (max 2 visible + overflow count). `EmailRowView` caches `nudgeText` as a stored `let` in `init` for "Received N days ago" hints (avoids per-render Calendar computation).
- `CategoryTabBar` — Horizontal tab bar for inbox category filtering (Primary, Social, Updates, etc.).
- `EmailHoverSummaryView` — AI-generated summary tooltip on email row hover.
- `EmailContextMenu` — Right-click context menu with reply, reply all, forward, archive, delete, star, snooze (uses `SnoozePreset.defaults()`), labels.
- `EmailSelectionManager` — Utility enum for multi-select logic (Cmd+click toggle, Shift+click range, single click, arrow navigation).
- `BulkActionBarView` — Floating action bar for bulk operations on selected emails.

### `EmailDetail/`
Right column — thread view, HTML rendering (`HTMLEmailView` via WKWebView), attachments, sender info popover, tracker blocking UI, label picker.
- `ReplyBarView` — Inline quick reply with To/Cc/Bcc fields, draft persistence, auto-save, discard confirmation, and smart reply chip support. Custom `init` for `@State` initialization. `.task(id: email.id)` cancels `saveTask` and `loadDraftTask`, resets `ComposeViewModel`, and reloads quick replies on email change. Send success (toast + collapse) driven reactively via `.onChange(of: composeVM.isSent)`.
- `DetailPaneView` — Contextual empty state (icon + message per folder). Uses `EmailDetailActions.contentActions` factory to build shared content-level actions.
- `InsightCardView` — Apple Intelligence insight card (summary, action items, key dates) via Foundation Models.
- `SmartReplyChipsView` — AI-generated reply suggestion chips below the thread (wired via `EmailDetailView`).
- `LabelEditorView` — Label picker with AI-suggested labels and manual search. Uses `precomputed` tuple property to avoid redundant linear scans per render.
- `ThreadMessageCardView` — Individual message card with quote stripping toggle, click-to-show sender info popover (`.onTapGesture`, `.pointerStyle(.link)`).
- `GmailThreadMessageView` — Utility enum for HTML computation and quote stripping.
- `AttachmentChipView` — Individual attachment display with preview/download buttons.
- `AttachmentPreviewView` — Full-screen attachment preview (images, PDFs, zoom, download). Caches decoded `NSImage` via `@State private var decodedImage` + `.task(id: data)` to avoid repeated decoding.
- `EmailDetailSkeletonView` — Loading placeholder skeleton UI.
- `CalendarInviteCardView` — Calendar invite card with RSVP buttons.
- `OriginalMessageView` — Email source viewer (headers, message ID, delivery delay, copy-to-clipboard). Uses cached static `DateFormatter`s and `FileUtils.saveWithPanel` for saving the raw source.

### `Compose/`
Email composer — `ComposeView` for the full compose form with rich text editor, send-as alias picker, signature management, attachment list, and discard confirmation. Custom `init` for proper `@State` initialization.
- `AutocompleteTextField` — Contact suggestions in To/Cc/Bcc fields.
- `ScheduleSendButton` — Send button with schedule-send popover (date picker for deferred delivery).

### `Attachments/`
Attachment explorer with grid view, thumbnails, file type filtering, and search.

### `Settings/`
Tabbed settings view (Accounts, General, Signatures, Filters, Advanced) registered as a macOS `Settings` scene — opens via Cmd+,. `SettingsView` uses `@AppStorage("com.vikingz.serif.selectedAccountID")` for reactive account ID (updates when user switches accounts), `AppearanceManager` via `@Bindable`, and closures (`onReauthorize`, `loadSendAs`, `updateSignature`) from `SerifApp`. Uses `@AppStorage` for other settings (notifications, undo duration, directory contacts sync).
- `AccountsSettingsView` — Account management: reorder (drag + up/down buttons), set default, accent color picker from palette. Refreshes from `AccountStore.shared` on appear. Context menu with "Set as Default" and accent color submenu.
- `SignaturesSettingsView` — Signature management per send-as alias. Takes explicit `loadSendAs` and `onUpdateSignature` closures.
- `FiltersSettingsView` — Gmail filter list with create/edit/delete actions.
- `FilterEditorView` — Filter rule editor (criteria + actions) for creating/editing Gmail filters.

### `Onboarding/`
Sign-in / welcome screen with OAuth flow. `OnboardingView` hides traffic lights on appear; the `else` branch on dismissal restores window state (movable, standard titlebar, background color).
- `GoogleLogo` — Multicolor Google "G" logo in SwiftUI.

### `Common/`
Shared reusable components:
| File | Role |
|------|------|
| `AccountAvatarBubble` | Account switcher avatar with profile picture/initial fallback |
| `AvatarView` | Circular avatar with initials fallback or profile image |
| `SearchBarView` | Search input with clear button |
| `LabelChipView` | Colored label pill |
| `ThemePickerView` | Segmented picker for System / Light / Dark appearance |
| `SettingsCardsView` | Settings UI with behavior, signature, account cards |
| `SlidePanel` | Animated side panel overlay (help, debug, previews) with Liquid Glass background |
| `FormattingToolbar` | Rich text toolbar for compose/reply |
| `WebRichTextEditor` | WKWebView-based HTML editor |
| `UnifiedToastLayer` | Consolidated toast system (undo, offline, general) with priority ordering |
| `CommandPaletteView` | ⌘K command palette with fuzzy search and keyboard navigation |
| `SnoozePickerView` | Snooze date/time picker with preset options. Defines `SnoozePreset` model struct; uses `SnoozePreset.defaults()` for the preset list. |
| `DebugMenuView` | API logs, cache controls. Uses file-private `DebugViewModel` wrapper (no direct `AttachmentDatabase` access). |
| `ShortcutsHelpView` | Keyboard shortcuts reference |
| `SerifCommands` | macOS menu bar commands (File, Edit, View custom menus) |
| `AttachmentChipRow` | Reusable horizontal attachment chip list (used in ComposeView and ReplyBarView) |
| `SlidePanelsOverlay` | Overlay container for slide panels (help, debug, original message, attachment preview, email preview, web browser). Receives `mailDatabase` and `attachmentIndexer` for detail views. Preview actions (`onToggleStar`, `onMarkUnread`, `onMessagesRead`) are closures routed through `AppCoordinator` → `EmailActionCoordinator`/`MailboxViewModel` for optimistic UI + offline support. Uses `EmailDetailActions.contentActions` factory and `FileUtils.saveWithPanel` for content-level actions. |

### `Components/`
Shared styled components:
| File | Role |
|------|------|
| `CardStyle` | Base-plane card container (`.quinary` fill + `.separator` stroke) for settings and detail cards. `CompactCardStyle` variant with tighter padding (`Spacing.md`/`Spacing.sm`) for inline banners (tracker, insight). |
| `BadgeView` | Numeric badge pill (unread counts) |

## Intents (App Intents)

`Serif/Intents/` — App Intents for Shortcuts, Spotlight, and Siri integration.

| File | Role |
|------|------|
| `EmailEntity.swift` | `AppEntity` + `IndexedEntity` representing an email for Shortcuts / Spotlight |
| `OpenEmailIntent.swift` | Opens an email in Serif by message ID (resolves account via `IntentHelpers`) |
| `ComposeEmailIntent.swift` | Opens a new compose window with optional pre-filled fields |
| `SearchEmailIntent.swift` | Searches emails by query string |
| `IntentHelpers.swift` | Shared helper: `findOwnerAccount(for:)` scans all account DBs to find the owner of a message ID |
| `MarkAsReadIntent.swift` | Marks an email as read (resolves account via `IntentHelpers`) |
