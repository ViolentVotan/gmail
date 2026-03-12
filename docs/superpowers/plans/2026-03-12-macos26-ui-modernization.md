# macOS 26 UI/UX Modernization — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modernize Serif to fully adopt Apple's macOS 26 design system — NavigationSplitView, Liquid Glass, system toolbar, semantic typography, accessibility, and platform integration.

**Architecture:** Layered migration in dependency order. Layer 1 (NavigationSplitView + sidebar + toolbar) is the foundation and MUST be committed atomically since ContentView and SidebarView have coupled signatures. Layer 2 (settings, accessibility, fonts, swipe, menus) builds on it independently. Layer 3 (Spotlight, focus) adds new capabilities.

**Tech Stack:** Swift 6.2, SwiftUI (macOS 26+), CoreSpotlight

**Spec:** `docs/superpowers/specs/2026-03-12-macos26-ui-modernization-design.md`

**Key references:**
- `ComposeMode` enum: `Serif/Models/ComposeMode.swift` — cases: `.new`, `.reply(to:subject:quotedBody:replyToMessageID:threadID:)`, `.replyAll(to:cc:subject:quotedBody:replyToMessageID:threadID:)`, `.forward(subject:quotedBody:)`
- `EmailDetailViewModel`: `Serif/ViewModels/EmailDetailViewModel.swift` — `init(accountID: String)`, has `replyMode(email:)`, `replyAllMode(email:)`, `forwardMode(email:)` factory methods
- `InboxCategory`: has `.displayName`, `.icon`, `.rawValue` (API strings like "ALL_INBOX")
- `Folder`: has `.icon`, `.rawValue` (human-readable like "Inbox")
- UserDefaults keys: `UserDefaultsKey.undoDuration` = `"undoDuration"`, `UserDefaultsKey.refreshInterval` = `"refreshInterval"`

---

## Chunk 1: Foundation — NavigationSplitView + Sidebar + Toolbar (Atomic)

> **IMPORTANT:** Tasks 1-3 in this chunk MUST be committed together as a single atomic commit. ContentView's call to SidebarView and the SidebarView struct must have matching signatures, and both depend on removing `sidebarExpanded` from AppCoordinator.

### Task 1: Rewrite SerifApp, ContentView, SidebarView, and AppCoordinator (Atomic)

**Files:**
- Modify: `Serif/SerifApp.swift:20-21` (remove window style overrides)
- Modify: `Serif/ContentView.swift` (rewrite `mainLayout`, `toolbarContent`, remove `sidebarToggleButton`)
- Modify: `Serif/Views/Sidebar/SidebarView.swift` (complete rewrite — List-based sidebar)
- Modify: `Serif/ViewModels/AppCoordinator.swift:30` (remove `sidebarExpanded`)
- Modify: `Serif/Views/Common/SerifCommands.swift:111-120` (remove sidebarExpanded.toggle())

- [ ] **Step 1: Remove window style overrides from SerifApp.swift**

In `Serif/SerifApp.swift`, delete lines 20-21:
```swift
// DELETE these two lines:
.windowStyle(.titleBar)
.windowToolbarStyle(.unifiedCompact)
```

- [ ] **Step 2: Remove `sidebarExpanded` from AppCoordinator**

In `Serif/ViewModels/AppCoordinator.swift`, delete line 30:
```swift
// DELETE:
var sidebarExpanded = false
```

- [ ] **Step 3: Fix SerifCommands viewMenu (depends on Step 2)**

In `Serif/Views/Common/SerifCommands.swift`, replace `viewMenu` (lines 111-120). The old code calls `coordinator?.sidebarExpanded.toggle()` which will no longer compile:

```swift
private var viewMenu: some Commands {
    CommandGroup(after: .toolbar) {
        // NavigationSplitView provides its own sidebar toggle (⌘⌥S)
        // Keep this shortcut as an additional alias — no-op since system handles it
        Button("Toggle Sidebar") { }
            .keyboardShortcut("s", modifiers: [.command, .control])
    }
}
```

- [ ] **Step 4: Rewrite SidebarView as List-based sidebar**

Replace entire `Serif/Views/Sidebar/SidebarView.swift`. The new version removes:
- `@Binding var showSettings`, `isExpanded`, `showHelp`, `showDebug`
- All manual width/collapse logic, `.regularMaterial` background, RoundedRectangle clipping
- Bottom Settings/Help/Debug buttons
- Logo, content height tracking, fade gradient

```swift
import SwiftUI

struct SidebarView: View {
    @Binding var selectedFolder: Folder
    @Binding var selectedInboxCategory: InboxCategory?
    @Binding var selectedLabel: GmailLabel?
    @Binding var selectedAccountID: String?
    var authViewModel: AuthViewModel
    var categoryUnreadCounts: [InboxCategory: Int] = [:]
    var userLabels: [GmailLabel] = []
    var onRenameLabel: ((GmailLabel, String) -> Void)?
    var onDeleteLabel: ((GmailLabel) -> Void)?

    @State private var labelToRename: GmailLabel?
    @State private var labelToDelete: GmailLabel?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            AccountSwitcherView(
                accounts: authViewModel.accounts,
                selectedAccountID: $selectedAccountID,
                isExpanded: true,
                onSignIn: { await authViewModel.signIn() },
                isSigningIn: authViewModel.isSigningIn
            ) { }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)

            if let account = authViewModel.accounts.first(where: { $0.id == selectedAccountID }) {
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            List {
                Section("Mailbox") {
                    ForEach(Folder.allCases.filter { $0 != .labels }) { folder in
                        if folder == .inbox {
                            DisclosureGroup {
                                ForEach(InboxCategory.allCases) { category in
                                    Button {
                                        selectedFolder = .inbox
                                        selectedInboxCategory = category
                                    } label: {
                                        Label(category.displayName, systemImage: category.icon)
                                    }
                                    .badge(categoryUnreadCounts[category] ?? 0)
                                }
                            } label: {
                                Button {
                                    selectedFolder = .inbox
                                    selectedInboxCategory = .all
                                } label: {
                                    Label(folder.rawValue, systemImage: folder.icon)
                                }
                            }
                        } else {
                            Button {
                                selectedFolder = folder
                                selectedInboxCategory = nil
                            } label: {
                                Label(folder.rawValue, systemImage: folder.icon)
                            }
                        }
                    }
                }

                if !userLabels.isEmpty {
                    Section("Labels") {
                        ForEach(userLabels) { label in
                            Button {
                                selectedFolder = .labels
                                selectedLabel = label
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(hex: label.color ?? "#888888"))
                                        .frame(width: 8, height: 8)
                                    Text(label.name)
                                }
                            }
                            .contextMenu {
                                Button("Rename...") {
                                    labelToRename = label
                                    renameText = label.name
                                }
                                Button("Delete", role: .destructive) {
                                    labelToDelete = label
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .alert("Rename Label", isPresented: Binding(
            get: { labelToRename != nil },
            set: { if !$0 { labelToRename = nil } }
        )) {
            TextField("Label name", text: $renameText)
            Button("Cancel", role: .cancel) { labelToRename = nil }
            Button("Save") {
                if let label = labelToRename, !renameText.isEmpty {
                    onRenameLabel?(label, renameText)
                }
                labelToRename = nil
            }
        } message: {
            Text("Enter a new name for this label.")
        }
        .alert("Delete Label", isPresented: Binding(
            get: { labelToDelete != nil },
            set: { if !$0 { labelToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { labelToDelete = nil }
            Button("Delete", role: .destructive) {
                if let label = labelToDelete { onDeleteLabel?(label) }
                labelToDelete = nil
            }
        } message: {
            Text("Are you sure? This will remove the label from all messages.")
        }
    }
}
```

Note: `InboxCategory.displayName` and `.icon` already exist on the enum — no additions needed. `Folder.icon` also exists. The sidebar does NOT use `List(selection:)` because the selection model spans multiple types (folders, inbox categories, labels). Instead, each row uses a `Button` that sets the appropriate state. The system sidebar List style still provides Liquid Glass appearance.

- [ ] **Step 5: Rewrite ContentView mainLayout with NavigationSplitView**

Replace `ContentView.mainLayout` (lines 39-131) with:

```swift
private var mainLayout: some View {
    ZStack {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selectedFolder: $coordinator.selectedFolder,
                selectedInboxCategory: $coordinator.selectedInboxCategory,
                selectedLabel: $coordinator.selectedLabel,
                selectedAccountID: $coordinator.selectedAccountID,
                authViewModel: coordinator.authViewModel,
                categoryUnreadCounts: coordinator.mailboxViewModel.categoryUnreadCounts,
                userLabels: coordinator.mailboxViewModel.labels.filter { !$0.isSystemLabel },
                onRenameLabel: { label, newName in Task { await coordinator.renameLabel(label, to: newName) } },
                onDeleteLabel: { label in Task { await coordinator.deleteLabel(label) } }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } content: {
            if coordinator.selectedFolder == .attachments {
                AttachmentExplorerView(
                    store: coordinator.attachmentStore,
                    panelCoordinator: coordinator.panelCoordinator,
                    accountID: coordinator.accountID,
                    onViewMessage: { messageId in
                        coordinator.navigateToMessage(gmailMessageID: messageId)
                    },
                    onDownloadAttachment: { messageID, attachmentID, accountID in
                        try await GmailMessageService.shared.getAttachment(
                            messageID: messageID, attachmentID: attachmentID, accountID: accountID
                        )
                    }
                )
            } else {
                ListPaneView(
                    emails: coordinator.displayedEmails,
                    isLoading: coordinator.listIsLoading,
                    selectedFolder: $coordinator.selectedFolder,
                    searchResetTrigger: coordinator.searchResetTrigger,
                    selectedEmail: $coordinator.selectedEmail,
                    selectedEmailIDs: $coordinator.selectedEmailIDs,
                    searchFocusTrigger: $coordinator.searchFocusTrigger,
                    coordinator: coordinator
                )
            }
        } detail: {
            if coordinator.selectedFolder != .attachments {
                DetailPaneView(
                    selectedEmail: coordinator.selectedEmail,
                    selectedEmailIDs: coordinator.selectedEmailIDs,
                    selectedFolder: coordinator.selectedFolder,
                    displayedEmails: coordinator.displayedEmails,
                    coordinator: coordinator
                )
            }
        }

        KeyboardShortcutsView(coordinator: coordinator)

        OfflineToastView()
            .zIndex(4)

        UndoToastView()
            .zIndex(5)

        ToastOverlayView()
            .zIndex(6)

        SlidePanelsOverlay(
            panels: coordinator.panelCoordinator,
            appearanceManager: appearanceManager,
            authViewModel: coordinator.authViewModel,
            selectedAccountID: $coordinator.selectedAccountID,
            undoDuration: $coordinator.undoDuration,
            refreshInterval: $coordinator.refreshInterval,
            lastRefreshedAt: coordinator.lastRefreshedAt,
            signatureForNew: $coordinator.signatureForNew,
            signatureForReply: $coordinator.signatureForReply,
            sendAsAliases: coordinator.mailboxViewModel.sendAsAliases,
            onAliasesUpdated: {
                Task { await coordinator.mailboxViewModel.loadSendAs() }
            },
            onRefreshContacts: { accountID in
                await GmailProfileService.shared.refreshContacts(accountID: accountID)
            },
            onSaveSignature: { sendAsEmail, signature, accountID in
                try await GmailProfileService.shared.updateSignature(
                    sendAsEmail: sendAsEmail, signature: signature, accountID: accountID
                )
            },
            attachmentStore: coordinator.attachmentStore,
            mailStore: coordinator.mailStore
        )
    }
}
```

- [ ] **Step 6: Add columnVisibility state to ContentView**

Add after line 5 (`@State private var coordinator = AppCoordinator()`):
```swift
@State private var columnVisibility: NavigationSplitViewVisibility = .all
```

- [ ] **Step 7: Replace toolbar content and remove sidebarToggleButton**

Replace `toolbarContent` (lines 135-156) and delete `sidebarToggleButton` (lines 158-170). NavigationSplitView provides a sidebar toggle automatically.

```swift
@ToolbarContentBuilder
private var toolbarContent: some ToolbarContent {
    if !coordinator.panelCoordinator.isAnyOpen {
        ToolbarItem(placement: .primaryAction) {
            Button { coordinator.composeNewEmail() } label: {
                Label("Compose", systemImage: "square.and.pencil")
            }
            .help("Compose (\u{2318}N)")
        }
    }
}
```

- [ ] **Step 8: Remove frame constraints from ListPaneView and DetailPaneView**

In `Serif/Views/EmailList/ListPaneView.swift`, replace line 30:
```swift
// FROM:
.frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
// TO:
.navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
```

In `Serif/Views/EmailDetail/DetailPaneView.swift`, delete lines 47-50:
```swift
// DELETE all four lines:
.frame(minWidth: 400)
.clipShape(RoundedRectangle(cornerRadius: 12))
.padding(.vertical, 8)
.padding(.trailing, 8)
```

- [ ] **Step 9: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -30`
Expected: BUILD SUCCEEDED

If there are remaining `sidebarExpanded` references, fix them. Check:
```
grep -rn "sidebarExpanded" Serif/ --include="*.swift"
```

- [ ] **Step 10: Commit**

```bash
git add -A && git commit -m "feat: migrate to NavigationSplitView with List-based sidebar

- Replace HStack three-column layout with NavigationSplitView
- Rewrite SidebarView: List(.sidebar) replaces custom ScrollView/VStack
- Remove sidebarExpanded, manual collapse logic, .regularMaterial background
- Remove .windowStyle/.windowToolbarStyle overrides
- Remove frame/clip/padding from ListPaneView and DetailPaneView
- System provides Liquid Glass floating sidebar and sidebar toggle"
```

---

### Task 2: Migrate email actions to window toolbar

**Files:**
- Modify: `Serif/ContentView.swift` (expand `toolbarContent`)

Note: The toolbar uses `EmailDetailViewModel` factory methods (`replyMode`, `replyAllMode`, `forwardMode`) to construct ComposeMode values. These factories need an `EmailDetailViewModel` instance which requires `accountID`. The toolbar creates a lightweight instance for compose mode construction only.

- [ ] **Step 1: Expand toolbar in ContentView**

Replace `toolbarContent` in `Serif/ContentView.swift` with:

```swift
@ToolbarContentBuilder
private var toolbarContent: some ToolbarContent {
    if !coordinator.panelCoordinator.isAnyOpen {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { coordinator.composeNewEmail() } label: {
                Label("Compose", systemImage: "square.and.pencil")
            }
            .help("Compose (\u{2318}N)")

            if let email = coordinator.selectedEmail {
                Button {
                    let vm = EmailDetailViewModel(accountID: coordinator.accountID)
                    coordinator.startCompose(mode: vm.replyMode(email: email))
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .help("Reply")

                if coordinator.selectedFolder != .archive {
                    Button {
                        coordinator.actionCoordinator.archiveEmail(email, selectNext: { coordinator.selectNext($0) })
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .help("Archive (\u{2318}E)")
                }

                if coordinator.selectedFolder != .trash {
                    Button {
                        coordinator.actionCoordinator.deleteEmail(email, selectNext: { coordinator.selectNext($0) })
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Delete (\u{2318}\u{232B})")
                }
            }
        }

        if let email = coordinator.selectedEmail {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    let vm = EmailDetailViewModel(accountID: coordinator.accountID)
                    coordinator.startCompose(mode: vm.forwardMode(email: email))
                } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                }
                .help("Forward")

                Button {
                    guard let msgID = email.gmailMessageID else { return }
                    let starred = coordinator.mailboxViewModel.messages.first(where: { $0.id == msgID })?.isStarred ?? email.isStarred
                    Task { await coordinator.mailboxViewModel.toggleStar(msgID, isStarred: starred) }
                } label: {
                    let starred = coordinator.mailboxViewModel.messages.first(where: { $0.id == email.gmailMessageID })?.isStarred ?? email.isStarred
                    Label(starred ? "Unstar" : "Star", systemImage: starred ? "star.fill" : "star")
                }
                .help("Toggle Star (\u{2318}L)")

                Button {
                    coordinator.actionCoordinator.markUnreadEmail(email)
                } label: {
                    Label("Mark Unread", systemImage: "envelope.badge")
                }
                .help("Mark Unread (\u{21E7}\u{2318}U)")

                Menu {
                    Button {
                        let vm = EmailDetailViewModel(accountID: coordinator.accountID)
                        coordinator.startCompose(mode: vm.replyAllMode(email: email))
                    } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }

                    if coordinator.selectedFolder == .archive || coordinator.selectedFolder == .trash {
                        Button {
                            coordinator.actionCoordinator.moveToInboxEmail(email, selectedFolder: coordinator.selectedFolder, selectNext: { coordinator.selectNext($0) })
                        } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
                    }

                    Divider()

                    Button {
                        if let msg = coordinator.mailboxViewModel.messages.first(where: { $0.id == email.gmailMessageID }) {
                            EmailPrintService.shared.printEmail(message: msg, email: email)
                        }
                    } label: { Label("Print", systemImage: "printer") }

                    Divider()

                    Button(role: .destructive) {
                        coordinator.actionCoordinator.markSpamEmail(email, selectNext: { coordinator.selectNext($0) })
                    } label: { Label("Report as Spam", systemImage: "exclamationmark.shield") }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More actions")
            }
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -30`

Note: `DetailToolbarView` is still used inside `EmailDetailView` for the unsubscribe button and in-context actions. We do NOT delete it — the window toolbar provides the primary actions and `DetailToolbarView` remains for contextual controls like Unsubscribe.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: migrate email actions to window toolbar

- Reply, Archive, Delete as primary toolbar actions with Liquid Glass
- Forward, Star, Mark Unread as secondary actions
- Overflow menu for Reply All, Move to Inbox, Print, Spam
- Uses EmailDetailViewModel factory methods for correct ComposeMode construction
- DetailToolbarView remains for contextual actions (Unsubscribe)"
```

---

## Chunk 2: Component Modernization

### Task 3: Create Settings scene and SettingsView

**Files:**
- Modify: `Serif/SerifApp.swift` (add Settings scene)
- Create: `Serif/Views/Settings/SettingsView.swift`
- Modify: `Serif/Views/Common/SlidePanelsOverlay.swift` (remove settingsPanel)
- Modify: `Serif/ViewModels/PanelCoordinator.swift` (remove showSettings)
- Modify: `Serif/Views/Common/SerifCommands.swift` (remove custom settings command, add Help command)

- [ ] **Step 1: Create SettingsView.swift**

Create `Serif/Views/Settings/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    // Use the same @AppStorage keys as AppCoordinator and UndoActionManager
    @AppStorage("undoDuration") private var undoDuration = 5
    @AppStorage("refreshInterval") private var refreshInterval = 120
    @AppStorage("showDebugMenu") private var showDebugMenu = false
    @AppStorage("aiLabelSuggestions") private var aiLabelSuggestions = true
    @AppStorage("appearancePreference") private var appearancePreference = "system"

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalTab
            }

            Tab("Advanced", systemImage: "wrench.and.screwdriver") {
                advancedTab
            }
        }
        .frame(width: 450, height: 300)
    }

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearancePreference) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Behavior") {
                Picker("Undo duration", selection: $undoDuration) {
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("20 seconds").tag(20)
                    Text("30 seconds").tag(30)
                }

                Picker("Auto-refresh interval", selection: $refreshInterval) {
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("60 minutes").tag(3600)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var advancedTab: some View {
        Form {
            Section("Intelligence") {
                Toggle("AI label suggestions", isOn: $aiLabelSuggestions)
            }

            Section("Developer") {
                Toggle("Show debug menu", isOn: $showDebugMenu)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

Note: This uses `@AppStorage` with the SAME keys as `AppCoordinator` (`"undoDuration"`, `"refreshInterval"`). Changes in SettingsView write to UserDefaults, and AppCoordinator's `didSet` hooks fire on next read. The `"appearancePreference"` key matches `AppearanceManager`. Accounts and Signatures tabs are omitted for now — they require more complex state sharing and will be added as follow-up.

- [ ] **Step 2: Add Settings scene to SerifApp.swift**

In `Serif/SerifApp.swift`, add after the `WindowGroup` scene (after the closing `}`  of `.commands { ... }`):

```swift
Settings {
    SettingsView()
}
```

- [ ] **Step 3: Remove settings panel from SlidePanelsOverlay**

In `Serif/Views/Common/SlidePanelsOverlay.swift`:
- Remove `settingsPanel` from `body` (line 22)
- Delete the entire `settingsPanel` computed property (lines 33-62)
- Remove parameters only used by settings: `appearanceManager`, `undoDuration`, `refreshInterval`, `lastRefreshedAt`, `signatureForNew`, `signatureForReply`, `sendAsAliases`, `onAliasesUpdated`, `onRefreshContacts`, `onSaveSignature`
- Keep: `panels`, `authViewModel`, `selectedAccountID`, `attachmentStore`, `mailStore`

- [ ] **Step 4: Update SlidePanelsOverlay call in ContentView**

Simplify the `SlidePanelsOverlay(...)` call in `ContentView.mainLayout` to pass only the remaining parameters.

- [ ] **Step 5: Remove showSettings from PanelCoordinator**

In `Serif/ViewModels/PanelCoordinator.swift`:
- Delete `var showSettings = false` (line 8)
- Remove `showSettings` from `isAnyOpen` (line 37: `showSettings || showHelp || ...` → `showHelp || ...`)
- Delete `showSettings = false` from `closeAll()` (line 42)
- Delete the `openSettings()` method (lines 51-55)

- [ ] **Step 6: Update SerifCommands**

In `Serif/Views/Common/SerifCommands.swift`:
- Delete `settingsMenu` (lines 124-131) and remove from `body` (line 36)
- Add Help menu command:

```swift
// Add to body:
helpMenu

// New computed property:
private var helpMenu: some Commands {
    CommandGroup(replacing: .help) {
        Button {
            coordinator?.panelCoordinator.showHelp = true
        } label: {
            Label("Keyboard Shortcuts", systemImage: "keyboard")
        }
    }
}
```

- [ ] **Step 7: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -30`

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: move settings to proper Settings scene

- Add tabbed SettingsView (General, Advanced)
- Register Settings scene in SerifApp — Cmd+, works automatically
- Remove settings SlidePanel from SlidePanelsOverlay
- Remove showSettings from PanelCoordinator
- Move Help to menu bar command
- Uses same @AppStorage keys as AppCoordinator for shared state"
```

---

### Task 4: Add accessibility modifiers throughout

**Files:**
- Modify: `Serif/Views/EmailList/EmailRowView.swift`
- Modify: `Serif/Views/Common/ToastOverlayView.swift`
- Modify: `Serif/Views/Common/AvatarView.swift`
- Modify: `Serif/Views/Components/BadgeView.swift`
- Modify: `Serif/Views/EmailList/BulkActionBarView.swift`

- [ ] **Step 1: Add accessibility to EmailRowView**

In `Serif/Views/EmailList/EmailRowView.swift`, add AFTER the `.background(PopoverAnchor(holder: popoverHolder))` on line 112 (NOT after `.buttonStyle` — PopoverAnchor must remain inside the accessibility element):

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel("\(email.sender.name), \(email.subject), \(email.preview)")
.accessibilityValue(email.isRead ? "Read" : "Unread")
.accessibilityAddTraits(isSelected ? .isSelected : [])
.accessibilityHint("Double-tap to read")
```

- [ ] **Step 2: Add accessibility to ToastOverlayView**

In `Serif/Views/Common/ToastOverlayView.swift`, add to the toast content view. `AccessibilityNotification` is available via SwiftUI — no additional import needed:

```swift
.accessibilityAddTraits(.isStatusElement)
.onAppear {
    if let toast = toastMgr.currentToast {
        AccessibilityNotification.Announcement(toast.message).post()
    }
}
```

- [ ] **Step 3: Add accessibility to AvatarView**

In `Serif/Views/Common/AvatarView.swift`, add to the avatar container:

```swift
.accessibilityLabel("\(initials) avatar")
.accessibilityAddTraits(.isImage)
```

- [ ] **Step 4: Add accessibility to BadgeView**

In `Serif/Views/Components/BadgeView.swift`, add:

```swift
.accessibilityLabel("\(count) unread")
```

- [ ] **Step 5: Add accessibility to BulkActionBarView buttons**

In `Serif/Views/EmailList/BulkActionBarView.swift`, add `.accessibilityLabel()` to each action button matching its label text.

- [ ] **Step 6: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -20`

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: add accessibility labels, hints, and traits

- EmailRowView: combined element with label, value (read/unread), .isSelected trait, hint
- ToastOverlayView: status element with VoiceOver announcement
- AvatarView: image trait with initials label
- BadgeView: unread count label
- BulkActionBarView: labeled action buttons"
```

---

### Task 5: Replace hardcoded fonts with semantic text styles

**Files:**
- Modify: All view files containing `.system(size:)` font calls

- [ ] **Step 1: Replace fonts in EmailRowView**

In `Serif/Views/EmailList/EmailRowView.swift`:
- Line 41: `.font(.system(size: 13, weight: email.isRead ? .medium : .semibold))` → `.font(.body.weight(email.isRead ? .medium : .semibold))`
- Line 47: `.font(.system(size: 11, weight: .bold, design: .rounded))` → `.font(.caption2.weight(.bold))`
- Line 56: `.font(.system(size: 11))` → `.font(.caption)`
- Line 61: `.font(.system(size: 12, weight: email.isRead ? .regular : .medium))` → `.font(.subheadline.weight(email.isRead ? .regular : .medium))`
- Line 66: `.font(.system(size: 11))` → `.font(.caption)`
- Line 77: `.font(.system(size: 9, weight: .medium))` → `.font(.caption2)`

- [ ] **Step 2: Replace fonts in EmailListView header**

In `Serif/Views/EmailList/EmailListView.swift`:
- Line 88: `.font(.system(size: 22, weight: .bold))` → `.font(.title2.bold())`
- Line 100, 115, 131: `.font(.system(size: 12, weight: .medium))` → `.font(.subheadline)`
- Line 149: `.font(.system(size: 12))` → `.font(.subheadline)`
- Line 151: `.font(.system(size: 9))` → `.font(.caption2)`

- [ ] **Step 3: Replace fonts in DetailToolbarView**

In `Serif/Views/EmailDetail/DetailToolbarView.swift`:
- Line 40, 42, 64: `.font(.system(size: 10/12, weight:))` → `.font(.caption2)` / `.font(.subheadline)`
- Line 137: `.font(.system(size: 13))` → `.font(.body)`
- Line 153: `.font(.system(size: 13))` → `.font(.body)`

- [ ] **Step 4: Replace fonts in SidebarRowViews**

In `Serif/Views/Sidebar/SidebarRowViews.swift`, replace all `.system(size:)` with semantic equivalents:
- Row text → `.font(.body)`
- Badge text → `.font(.caption2)`
- Section headers → `.font(.subheadline.weight(.semibold))`

- [ ] **Step 5: Search for remaining `.system(size:` and replace**

Search project-wide, excluding `OnboardingView` (separate concern):
```
grep -rn "\.system(size:" Serif/ --include="*.swift" | grep -v OnboardingView | grep -v ".build/"
```

Replace each occurrence with the appropriate semantic style per the spec mapping.

- [ ] **Step 6: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -20`

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: replace hardcoded fonts with semantic text styles

- .title2 for section headings, .body for primary text
- .subheadline for secondary text, .caption for tertiary
- .caption2 for badges and chips
- Enables Dynamic Type scaling automatically"
```

---

### Task 6: Replace custom swipe with .swipeActions()

**Files:**
- Modify: `Serif/Views/EmailList/EmailListView.swift` (convert ScrollView to List, add swipeActions)
- Delete: `Serif/Views/EmailList/SwipeableEmailRow.swift`

- [ ] **Step 1: Convert emailScrollView to List**

In `Serif/Views/EmailList/EmailListView.swift`, replace `emailScrollView` (lines 187-256). Also delete:
- `@State private var isRefreshing = false` (line 34)
- `private let swipeCoordinator = SwipeCoordinator.shared` (line 36)

New `emailScrollView`:

```swift
private var emailScrollView: some View {
    List(selection: $selectedEmailIDs) {
        ForEach(sortedEmails) { email in
            EmailRowView(
                email: email,
                isSelected: selectedEmailIDs.contains(email.id.uuidString),
                action: { handleTap(email: email) }
            )
            .tag(email.id.uuidString)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if selectedFolder != .archive {
                    Button {
                        onArchive?(email)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .tint(.gray)
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if selectedFolder != .trash {
                    Button(role: .destructive) {
                        onDelete?(email)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .contextMenu {
                EmailContextMenu(
                    email: email,
                    selectedFolder: selectedFolder,
                    onArchive: onArchive,
                    onDelete: onDelete,
                    onToggleStar: onToggleStar,
                    onMarkUnread: onMarkUnread,
                    onMarkSpam: onMarkSpam,
                    onUnsubscribe: onUnsubscribe,
                    onMoveToInbox: onMoveToInbox,
                    onDeletePermanently: onDeletePermanently,
                    onMarkNotSpam: onMarkNotSpam
                )
            }
        }

        if !emails.isEmpty && searchText.isEmpty {
            Color.clear
                .frame(height: 1)
                .onAppear { onLoadMore() }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }

        if isLoading && !emails.isEmpty {
            ProgressView()
                .scaleEffect(0.7)
                .tint(.gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
        }
    }
    .listStyle(.plain)
    .refreshable {
        await onRefresh?()
    }
    .focusable()
    .focusEffectDisabled(true)
    .onKeyPress(.upArrow) { navigateToPrevious(); return .handled }
    .onKeyPress(.downArrow) { navigateToNext(); return .handled }
    .onKeyPress(characters: CharacterSet(charactersIn: "e")) { _ in handleKeyE() }
    .onKeyPress(characters: CharacterSet(charactersIn: "s")) { _ in handleKeyS() }
    .onKeyPress(characters: CharacterSet(charactersIn: "u")) { _ in handleKeyU() }
    .onKeyPress(characters: CharacterSet(charactersIn: "r")) { _ in handleKeyR() }
}
```

Note: `selectedEmailIDs` is `Set<String>` and `.tag(email.id.uuidString)` provides `String` tags — types already match. The infinite-scroll sentinel has `.listRowSeparator(.hidden)` and `.listRowBackground(Color.clear)` to prevent visible artifacts.

- [ ] **Step 2: Update emailListSection skeleton**

Replace the skeleton loading section (lines 172-185):

```swift
@ViewBuilder
private var emailListSection: some View {
    if isLoading && emails.isEmpty {
        List {
            ForEach(0..<9, id: \.self) { _ in
                EmailSkeletonRowView()
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    } else {
        emailScrollView
    }
}
```

- [ ] **Step 3: Delete SwipeableEmailRow.swift**

```bash
git rm Serif/Views/EmailList/SwipeableEmailRow.swift
```

Also check for `SwipeCoordinator` references elsewhere — if the class is defined in that file and not imported elsewhere, the deletion should be clean.

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -30`

Common issues:
- `EmailRowView` may need its manual `.background(RoundedRectangle...)` adjusted for List context (List provides its own row highlighting)
- Check that `List(selection:)` with `Set<String>` works with the `EmailSelectionManager` — the selection manager writes directly to the `selectedEmailIDs` binding which the List will observe

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: replace custom swipe with .swipeActions()

- Convert ScrollView+LazyVStack to List for email rows
- Add .swipeActions for archive (trailing) and delete (leading)
- Replace PullToRefreshDetector with .refreshable
- Delete SwipeableEmailRow and SwipeCoordinator
- System provides haptics, Liquid Glass swipe, VoiceOver support"
```

---

### Task 7: Add SF Symbol icons to menu commands

**Files:**
- Modify: `Serif/Views/Common/SerifCommands.swift`

- [ ] **Step 1: Add icons to all menu items**

Replace the `messageMenu` and `mailboxMenu` in `SerifCommands.swift` with Label-wrapped versions:

Message menu — wrap each Button's string label with `Label(_, systemImage:)`:
- "Archive" → `Label("Archive", systemImage: "archivebox")`
- "Delete" → `Label("Delete", systemImage: "trash")`
- "Move to Inbox" → `Label("Move to Inbox", systemImage: "tray.and.arrow.down")`
- "Remove Star"/"Add Star" → `Label(_, systemImage: "star.slash"/"star")`
- "Mark as Unread"/"Mark as Read" → `Label(_, systemImage: "envelope.badge"/"envelope.open")`

Mailbox menu:
- "Compose New Message" → `Label("Compose New Message", systemImage: "square.and.pencil")`
- "Refresh" → `Label("Refresh", systemImage: "arrow.clockwise")`
- "Search" → `Label("Search", systemImage: "magnifyingglass")`

View menu:
- "Toggle Sidebar" → `Label("Toggle Sidebar", systemImage: "sidebar.left")`

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -20`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: add SF Symbol icons to all menu commands

- Matches macOS 26 HIG requirement for menu icons
- Icons follow Apple Mail conventions (archivebox, trash, star, etc.)"
```

---

## Chunk 3: New Capabilities

### Task 8: Add Spotlight indexing and Handoff

**Files:**
- Create: `Serif/Services/SpotlightIndexer.swift`
- Modify: `Serif/ContentView.swift` (add .userActivity and .onContinueUserActivity)
- Modify: `Serif/ViewModels/AppCoordinator.swift` (call indexer on email view)

- [ ] **Step 1: Create SpotlightIndexer.swift**

Create `Serif/Services/SpotlightIndexer.swift`:

```swift
import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    private let index = CSSearchableIndex.default()
    private var indexedCount = 0
    private let maxIndexed = 1000

    func indexEmail(_ email: Email) {
        let attributes = CSSearchableItemAttributeSet(contentType: .emailMessage)
        attributes.subject = email.subject
        attributes.authorNames = [email.sender.name]
        attributes.textContent = email.preview
        attributes.contentCreationDate = email.date
        attributes.mailboxes = [email.folder?.rawValue ?? "inbox"]

        let item = CSSearchableItem(
            uniqueIdentifier: "email-\(email.id)",
            domainIdentifier: "com.serif.emails",
            attributeSet: attributes
        )
        item.expirationDate = Calendar.current.date(byAdding: .day, value: 30, to: Date())

        Task.detached {
            try? await CSSearchableIndex.default().indexSearchableItems([item])
        }

        indexedCount += 1
        if indexedCount > maxIndexed {
            pruneAllEntries()
        }
    }

    /// Deletes all indexed entries when count exceeds maxIndexed.
    /// CSSearchableIndex does not support date-filtered deletion,
    /// so we purge the domain and reset the counter.
    private func pruneAllEntries() {
        Task.detached {
            try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["com.serif.emails"])
        }
        indexedCount = 0
    }
}
```

Note: Uses `Task.detached` for Spotlight API calls to avoid `@MainActor` isolation issues with the async completion-based API. The `indexSearchableItems` async variant runs on a background executor.

- [ ] **Step 2: Call indexer from AppCoordinator**

In `Serif/ViewModels/AppCoordinator.swift`, in `handleSelectedEmailChange(_:)`, add:

```swift
if let email = newValue {
    SpotlightIndexer.shared.indexEmail(email)
}
```

- [ ] **Step 3: Add userActivity and continuation to ContentView**

In `Serif/ContentView.swift`, add modifiers to the NavigationSplitView (inside `mainLayout`):

```swift
.userActivity("com.serif.viewEmail", isActive: coordinator.selectedEmail != nil) { activity in
    guard let email = coordinator.selectedEmail else { return }
    activity.title = email.subject
    activity.isEligibleForHandoff = true
    activity.isEligibleForSearch = true
    activity.userInfo = ["emailID": email.id.uuidString]
}
.onContinueUserActivity("com.serif.viewEmail") { activity in
    guard let emailID = activity.userInfo?["emailID"] as? String,
          let uuid = UUID(uuidString: emailID),
          let email = coordinator.mailboxViewModel.emails.first(where: { $0.id == uuid })
    else { return }
    coordinator.selectedEmail = email
    coordinator.selectedEmailIDs = [emailID]
}
```

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add Spotlight indexing and Handoff support

- SpotlightIndexer indexes viewed emails for Spotlight search
- NSUserActivity advertised when reading an email (Handoff)
- Activity continuation navigates to email on resume
- Purges all entries when count exceeds 1000
- Uses Task.detached for background Spotlight API calls"
```

---

### Task 9: Add @FocusState pane navigation

**Files:**
- Modify: `Serif/ContentView.swift` (add FocusState and keyboard handling)

- [ ] **Step 1: Add AppFocus enum and FocusState**

In `Serif/ContentView.swift`, add after `columnVisibility`:

```swift
enum AppFocus: Hashable {
    case sidebar
    case list
    case detail
}

@FocusState private var appFocus: AppFocus?
```

- [ ] **Step 2: Apply .focused() to each column**

In the NavigationSplitView, apply `.focused()` to each column's root content:

```swift
// Sidebar column:
SidebarView(...)
    .focused($appFocus, equals: .sidebar)

// Content column (ListPaneView or AttachmentExplorerView):
ListPaneView(...)
    .focused($appFocus, equals: .list)

// Detail column:
DetailPaneView(...)
    .focused($appFocus, equals: .detail)
```

- [ ] **Step 3: Add focus cycling via keyboard**

Add to the NavigationSplitView modifier chain. Uses Opt+Tab instead of Tab to avoid conflicting with system Tab behavior in Lists:

```swift
.onKeyPress(.tab, modifiers: .option) {
    switch appFocus {
    case .sidebar: appFocus = .list
    case .list:    appFocus = .detail
    case .detail:  appFocus = .sidebar
    case nil:      appFocus = .list
    }
    return .handled
}
.onKeyPress(.tab, modifiers: [.option, .shift]) {
    switch appFocus {
    case .sidebar: appFocus = .detail
    case .list:    appFocus = .sidebar
    case .detail:  appFocus = .list
    case nil:      appFocus = .list
    }
    return .handled
}
```

Note: Uses Opt+Tab / Opt+Shift+Tab instead of plain Tab to avoid intercepting system Tab navigation within Lists and text fields.

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add @FocusState pane navigation

- Opt+Tab cycles focus: sidebar → list → detail
- Opt+Shift+Tab cycles in reverse
- Uses Option modifier to avoid conflict with system Tab behavior"
```

---

## Final Verification

### Task 10: Build, verify, and final commit

- [ ] **Step 1: Full clean build**

```bash
xcodebuild -scheme Serif -configuration Debug clean build 2>&1 | tail -30
```

- [ ] **Step 2: Verify no remaining `.system(size:` outside onboarding**

```
grep -rn "\.system(size:" Serif/ --include="*.swift" | grep -v OnboardingView | grep -v ".build/"
```

Fix any remaining instances.

- [ ] **Step 3: Verify no remaining `sidebarExpanded` references**

```
grep -rn "sidebarExpanded" Serif/ --include="*.swift"
```

Should return zero results.

- [ ] **Step 4: Verify no remaining `showSettings` references**

```
grep -rn "showSettings" Serif/ --include="*.swift" | grep -v ".build/"
```

Should return zero results.

- [ ] **Step 5: Final commit if any fixes were needed**

```bash
git add -A && git commit -m "fix: cleanup remaining hardcoded fonts and stale references"
```
