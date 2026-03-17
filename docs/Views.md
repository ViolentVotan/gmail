# Views

SwiftUI views. UI presentation only — no business logic.

## Guidelines

- **No business logic in views.** Views read state from ViewModels and call callbacks. They do not:
  - Call Services or APIs directly
  - Perform data transformations beyond simple formatting
  - Contain persistence logic
- **No hardcoded colors.** Use SwiftUI semantic colors (`.primary`, `.secondary`, `.tertiary`, `Color.accentColor`). Use `.cardStyle()` for Base-plane content cards, `.glassEffect(.regular)` for Navigation-plane surfaces, and `.floatingPanelStyle()` for Transient-plane overlays. Use `Spacing`, `CornerRadius`, `Typography`, and `VikAnimation` tokens from `DesignTokens.swift`.
- **Action structs over individual closures.** Views receive callbacks via action structs (`EmailListActions`, `EmailDetailActions`) rather than dozens of individual closure parameters. Only top-level views (ListPaneView, DetailPaneView) construct these structs and wire them to ViewModels/coordinators.
- **Small, composable views.** Extract reusable components into `Common/`. One concern per file.
- **Animations belong in views**, not in ViewModels or Services.
- **Property wrappers**: `@State` for owning `@Observable` objects (not `@StateObject`). `@Bindable` for write access to bindings on `@Observable` objects (not `@ObservedObject`). `@Environment` with `@Entry` macro for custom environment keys.
- **onChange syntax**: use `onChange(of:) { oldValue, newValue in }` (two-parameter closure).
- **`WKNavigationDelegate` / `WKUIDelegate` coordinators** (`WebRichTextEditorCoordinator`, `SearchBarView.Coordinator`) are marked `final` — do not subclass them.
- **ContentView** routes quick-reply and attachment download through `AppCoordinator` (`handleQuickReply`, `downloadAttachment`) rather than handling them inline. `withLifecycle` is split into `LifecycleStateModifier` + `LifecycleNotificationModifier` (type-checker fix). `LifecycleStateModifier` receives `snoozeCount`/`scheduledCount` as explicit `Int` props (avoids over-subscribing to all `@Observable` mutations on the singleton stores). Reconnect triggers incremental sync.

## Subfolders

### `Sidebar/`
Left column — fixed-width, collapsible. **Expanded** (240pt): `List(.sidebar)` with folder navigation (Inbox is a flat button — category filtering lives in `CategoryTabBar`), account switcher, labels (8pt circle color indicators, `Section("Labels")` header), context menus. **Collapsed** (52pt icon-only): folder SF Symbol icons with Liquid Glass hover states (`GlassEffectContainer`, `.glassEffect(.regular.interactive())` on hover/selection, `.identity` when idle), compact account avatar, icon-only sync bubble, and labels popover button (tag icon, `.trailing` popover). Toggle via `⌘\` or toolbar button; `onToggleSidebar` callback wired from `ContentView`. `AccountSwitcherView` uses closure-based callbacks (`onSetAsDefault`, `onSetAccentColor`) wired from `SidebarView` — no direct `AccountStore` access. `isExpanded: false` on `AccountSwitcherView` in collapsed mode triggers `onExpandSidebar` on avatar tap.
- `SyncBubbleView` — Transient liquid glass sync status bubble (driven by `SyncProgressManager`). `isCompact` mode renders icon-only in a 32pt glass circle (used in collapsed sidebar).
- `SidebarView` — Conditional debug button (reads `@AppStorage("showDebugMenu")`). Width is fixed in both states (`min=ideal=max`), not user-resizable.

### `EmailList/`
Middle column — resizable width (300–480pt, ideal 380pt). Email rows with native `.swipeActions()` (archive/delete), search, `.refreshable` pull-to-refresh, multi-select with bulk actions. Uses `List(selection:)` for row rendering. Date-based sort orders show section headers (Today, Yesterday, This Week, Last Week, month/year). Email rows use Liquid Glass hover/selection (`.glassEffect(.regular.interactive())` after `.buttonStyle(.plain)`) with entrance animation (`hasAppeared` state — opacity+offset spring on first `onAppear`). Gmail labels and AI classification tags merge into a single capped badge row (max 1 label visible by default, expands to 2 on hover + overflow count). `EmailRowView` caches `nudgeText` as a stored `let` property (computed once in `init`, not per-render) for "Received N days ago" hints. Accessibility rotor filter properties are inlined into rotor closures (no separate stored properties). `EmailListView` has a midnight refresh `.task` that sleeps until the next midnight and triggers a re-render so "Today"/"Yesterday" section headers stay correct. Priority filter toggle (flag icon, glass background) lives in `EmailListView`'s search header row next to the sort menu (shown only for inbox).
- `CategoryTabBar` — Horizontal tab bar for inbox category filtering (All, Primary, Social, Promotions, Updates, Forums). Selected tab uses `.glassEffect(.regular.interactive())` with a sliding `matchedGeometryEffect` capsule indicator (`@Namespace`, id `"activeTab"`) that smoothly animates between tabs via `VikAnimation.springSnappy`. Unselected tabs show `.glassEffect(.regular)` on hover with `.snappy` animation. 8pt tab padding; `ScrollView` fallback for narrow windows.
- `EmailHoverSummaryView` — AI-generated summary tooltip on email row hover.
- `EmailContextMenu` — Right-click context menu with reply, reply all, forward, archive, delete, star, snooze (uses `SnoozePreset.defaults()`), unsnooze (visible in snoozed folder), labels.
- `EmailSelectionManager` — Utility enum for multi-select logic (Cmd+click toggle, Shift+click range, single click, arrow navigation).
- `BulkActionBarView` — Floating action bar for bulk operations on selected emails.
- `ListPaneView` — Top-level list pane that constructs `EmailListActions` and wires them to ViewModels/coordinators. Crossfade animation on category tab switch (`.animation(VikAnimation.contentSwitch)` + `.contentTransition(.opacity)`). Wires `onMarkRead` to `EmailActionCoordinator.markReadEmail`. Bulk and single-email action closures use `Task { await ... }` for async VM calls.

### `EmailDetail/`
Right column — thread view, HTML rendering (`HTMLEmailView` via WKWebView, uses `WeakScriptMessageHandler` proxy to avoid WKWebView retain cycles, bidirectional WCAG contrast enforcement for both light and dark mode, Live Text/ImageAnalyzer disabled via private SPI `_setTextExtractionEnabled` to prevent Vision framework use-after-free crash — Apple bug in macOS 26.3.1), attachments, sender info popover, tracker blocking UI, label picker. `EmailDetailView` registers `NSUserActivity` for Siri onscreen awareness and offers `.translationPresentation()` for on-device email translation. **Content arrival cascade**: `showMetadata`/`showConversation` states drive staggered opacity+offset reveal (header first, conversation 80ms later). **Staggered thread expand**: thread message cards animate with `DurationToken.stagger` (40ms) delay per card index via `Array(allMessages.enumerated())`.
- `ReplyBarView` — Inline quick reply with `AutocompleteTextField` for To/Cc/Bcc fields, `ScheduleSendButton` for deferred delivery, draft persistence, auto-save, discard confirmation, compose-side translation (`.translationPresentation` triggered by `editorState.translationRequested`), and smart reply chip support. Custom `init` for `@State` initialization. `.task(id: email.id)` cancels `saveTask` and `loadDraftTask`, resets `ComposeViewModel`, and reloads quick replies on email change. Send success (toast + collapse) driven reactively via `.onChange(of: composeVM.isSent)`. `ClickOutsideDetector` uses `superview` bounds instead of zero-size anchor for hit testing.
- `DetailPaneView` — Branded contextual empty state (56pt ultraLight icon with `OpacityToken.disabled` tint and `.breathe` symbol effect, folder-specific title/description, VoiceOver-combined). **Directional content switching**: transitions use `.push(from: selectionDirection)` — `.top` when navigating to an email above in the list, `.bottom` when below (direction tracked via `AppCoordinator.selectionDirection`, computed in ContentView's `.onChange(of: selectedEmail)`). **Trackpad swipe navigation**: horizontal `DragGesture` on the detail pane navigates prev/next email via `navigatePrevious`/`navigateNext` callbacks (wired to `AppCoordinator.selectPrevious()`/`.selectNextEmail()`). Smooth crossfade transition between email selections (`.animation(VikAnimation.contentSwitch)`). Uses `EmailDetailActions.contentActions` factory to build shared content-level actions. Action closures wrap async VM/coordinator calls in `Task { await ... }` (cascaded from async EmailActionCoordinator/MailboxViewModel changes).
- `InsightCardView` — Apple Intelligence insight card (summary, action items, key dates) via Foundation Models.
- `SmartReplyChipsView` — AI-generated reply suggestion chips below the thread (wired via `EmailDetailView`).
- `LabelEditorView` — Label picker with AI-suggested labels and manual search. Uses `@State` cached properties (`cachedCurrentUser`, `cachedItems`, `cachedShowCreate`, `cachedShouldShowDropdown`) with `onChange`-driven `recomputeLabelData()` to avoid redundant linear scans per render.
- `HTMLEmailView` — WKWebView-based HTML email renderer (`NSViewRepresentable`). Uses `PassthroughWebView` (scroll-through subclass), `WeakScriptMessageHandler` (prevents WKWebView retain cycles), bidirectional WCAG contrast enforcement, and Live Text disabled via private SPI. `Coordinator` handles navigation delegation and JS bridge.
- `SenderInfoPopover` — Sender detail popover showing from display name, sent-by domain, formatted date, with info/security rows and suspicious-domain highlighting.
- `TrackerBannerView` — Tracker blocking notification banner showing count and grouped tracker details with allow/dismiss actions. `groupedTrackers` is a stored `let` computed once in `init` (avoids per-render dictionary allocation).
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
- `ScheduleSendButton` — Send button with schedule-send popover (date picker for deferred delivery). `ComposeView.scheduleEmail(at:)` mirrors `sendEmail()` field population before calling `scheduleSend`.

### `Attachments/`
Attachment explorer with grid view, thumbnails, file type filtering, and search.

### `Settings/`
Tabbed settings view (Accounts, General, Signatures, Filters, Advanced) registered as a macOS `Settings` scene — opens via Cmd+,. `SettingsView` uses `@AppStorage("com.vikingz.vik.selectedAccountID")` for reactive account ID (updates when user switches accounts), `AppearanceManager` via `@Bindable`, and closures (`onReauthorize`, `loadSendAs`, `updateSignature`) from `VikApp`. Uses `@AppStorage` for other settings (notifications, undo duration, directory contacts sync).
- `AccountsSettingsView` — Account management: reorder (drag + up/down buttons), set default, accent color picker from palette. Receives all mutation callbacks (`fetchAccounts`, `onSetAsDefault`, `onSetAccentColor`, `onMoveUp`, `onMoveDown`, `onReorder`) from `SettingsView` — no direct `AccountStore` access. Context menu with "Set as Default" and accent color submenu.
- `SignaturesSettingsView` — Signature management per send-as alias. Takes explicit `loadSendAs` and `onUpdateSignature` closures.
- `FiltersSettingsView` — Gmail filter list with create/edit/delete actions. Uses `.task(id: accountID)` to recreate `FiltersViewModel` on account switch.
- `FilterEditorView` — Filter rule editor (criteria + actions) for creating/editing Gmail filters.
- `SignatureEditorView` — Per-alias signature editor with rich text (`WebRichTextEditor`), save action, and error handling.

### `Onboarding/`
Sign-in / welcome screen with OAuth flow. Forces dark appearance via `.preferredColorScheme(.dark)` + `window.appearance = .darkAqua` for the dramatic dark aesthetic regardless of system setting. `OnboardingView` hides traffic lights on appear; the `else` branch on dismissal restores window state (movable, standard titlebar, background color, `window.appearance = nil`).
- `GoogleLogo` — Multicolor Google "G" logo in SwiftUI.

### `Common/`
Shared reusable components:
| File | Role |
|------|------|
| `AccountAvatarBubble` | Account switcher avatar with profile picture/initial fallback |
| `AvatarView` | Circular avatar (30pt in email list) with initials fallback (desaturated at 0.7 opacity) or profile image. Luminance guard: uses `.primary` instead of `.white` for initials when avatar background is light (luminance > 0.7). |
| `SearchBarView` | Search input with clear button, focus-reactive styling (icon color, accent background tint, border glow), smooth clear button transition (`.scale.combined(with: .opacity)`) |
| `LabelChipView` | Colored label pill with WCAG contrast adjustment (text color auto-adjusted against background via `adjustedForContrast`; respects increased contrast accessibility setting) |
| `SlidePanel` | Animated side panel overlay (help, debug, previews) with Liquid Glass background |
| `FormattingToolbar` | Rich text toolbar for compose/reply — bold, italic, underline, strikethrough, font size, text color, highlight color picker (`HighlightColorPopover`), font family picker, alignment, lists, indent, blockquote toggle, link insert (Cmd+K popover), translate globe button (sets `translationRequested` on editor state) |
| `WebRichTextEditor` | WKWebView-based HTML editor (uses `WeakScriptMessageHandler` proxy to avoid retain cycles). Split into 4 files: `WebRichTextEditor.swift` (SwiftUI wrapper), `WebRichTextEditorRepresentable.swift` (`NSViewRepresentable` with Writing Tools support via `config.writingToolsBehavior = .complete`), `WebRichTextEditorCoordinator.swift` (WKWebView delegate, JS bridge), `WebRichTextEditorState.swift` (`@Observable` state — includes `isBlockquote`, `highlightColor`, `fontFamily`, `linkPopoverRequest`, `translationRequested` properties and corresponding formatting methods; JS execution via `evalJS(_:)`) |
| `UnifiedToastLayer` | Consolidated toast system (undo, offline, general) with priority ordering. Full-screen overlay no longer sets `allowsHitTesting(false)`. |
| `CommandPaletteView` | ⌘K command palette with fuzzy search and keyboard navigation |
| `SnoozePickerView` | Snooze date/time picker with preset options. Defines `SnoozePreset` model struct; uses `SnoozePreset.defaults()` for the preset list. |
| `DebugMenuView` | API logs, cache controls. Uses file-private `DebugViewModel` wrapper (no direct `AttachmentDatabase` access). |
| `InAppBrowserView` | In-app web browser with glass toolbar (`GlassEffectContainer` grouping close, back, forward, URL bar, open-in-browser buttons) |
| `KeyboardShortcutsView` | Responder-aware keyboard event monitor (`KeyboardEventMonitor` NSViewRepresentable with `Coordinator`) for global shortcut handling |
| `ShortcutsHelpView` | Keyboard shortcuts reference |
| `VikCommands` | macOS menu bar commands (File, Edit, View custom menus) |
| `AttachmentChipRow` | Reusable horizontal attachment chip list (used in ComposeView and ReplyBarView) |
| `SlidePanelsOverlay` | Overlay container for slide panels (help, debug, original message, attachment preview, email preview, web browser). Receives `mailDatabase` and `attachmentIndexer` for detail views. Preview actions (`onToggleStar`, `onMarkUnread`, `onMessagesRead`) are closures routed through `AppCoordinator` → `EmailActionCoordinator`/`MailboxViewModel` for optimistic UI + offline support. Uses `EmailDetailActions.contentActions` factory and `FileUtils.saveWithPanel` for content-level actions. |

### `Components/`
Shared styled components:
| File | Role |
|------|------|
| `CardStyle` | Base-plane card container (`.quinary` fill + `.separator` stroke) for settings and detail cards. `CompactCardStyle` variant with tighter padding (`Spacing.md`/`Spacing.sm`) for inline banners (tracker, insight). |

## Intents (App Intents)

`Vik/Intents/` — App Intents for Shortcuts, Spotlight, and Siri integration via AssistantSchemas mail domain.

| File | Role |
|------|------|
| `EmailEntity.swift` | `MailMessageEntity` (`@AppEntity(schema: .mail.message)` + `IndexedEntity`), `MailAccountEntity`, `MailboxEntity`, `MailMessageEntityQuery`, `MailDraftEntity` + `MailDraftEntityQuery` (queries GRDB for drafts by ID, subject/recipient search, or recent suggestions). `typealias EmailEntity = MailMessageEntity` for backward compat. |
| `ComposeEmailIntent.swift` | `@AppIntent(schema: .mail.createDraft)` — creates a draft with recipients, subject, body |
| `SendDraftIntent.swift` | Sends an existing draft, with optional `sendLaterDate` for schedule-send |
| `ReplyMailIntent.swift` | Replies to an email with recipients, subject, body, attachments. Supports `isReplyAll` flag. |
| `ForwardMailIntent.swift` | Forwards an email to new recipients with optional body and attachments |
| `DeleteDraftIntent.swift` | Deletes one or more drafts |
| `MarkAsReadIntent.swift` | `UpdateMailIntent` (`@AppIntent(schema: .mail.updateMail)`) — handles isRead, isFlagged, mailbox changes. Shared `IntentError` enum. |
| `ArchiveEmailIntent.swift` | `@AppIntent(schema: .mail.archiveMail)` — archives emails |
| `TrashEmailIntent.swift` | `@AppIntent(schema: .mail.deleteMail)` — moves emails to trash |
| `FlagEmailIntent.swift` | Toggles star/flag on emails (plain `AppIntent` — no schema for flag-only) |
| `OpenEmailIntent.swift` | Opens an email in Vik by message ID (resolves account via `IntentHelpers`) |
| `SearchEmailIntent.swift` | Searches emails by query string (plain `AppIntent` — no `.mail.search` schema) |
| `IntentHelpers.swift` | Shared helper: `findOwnerAccount(for:)` scans all account DBs to find the owner of a message ID |
| `VikShortcuts.swift` | `AppShortcutsProvider` registering intents with Siri phrases |
