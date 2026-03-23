import SwiftUI

struct SidebarView: View {
    @Binding var selectedFolder: Folder
    @Binding var selectedInboxCategory: InboxCategory?
    @Binding var selectedLabel: GmailLabel?
    @Binding var selectedAccountID: String?
    var authViewModel: AuthViewModel
    var isCollapsed = false
    var userLabels: [GmailLabel] = []
    var viewMode: AppViewMode
    var calendarViewModel: CalendarViewModel?
    var miniAgendaEvents: [CalendarEvent]
    // MARK: - Action Callbacks — Navigation
    var onSwitchToMail: () -> Void
    var onSwitchToCalendar: () -> Void
    var onNavigateToEvent: (CalendarEvent) -> Void

    // MARK: - Action Callbacks — Label Management
    var onRenameLabel: ((GmailLabel, String) -> Void)?
    var onDeleteLabel: ((GmailLabel) -> Void)?

    // MARK: - Action Callbacks — Drag & Drop
    var onDropToTrash: ((String, String) -> Void)?
    var onDropToArchive: ((String, String) -> Void)?
    var onDropToSpam: ((String, String) -> Void)?
    var onDropToLabel: ((String, String, String) -> Void)?

    // MARK: - Action Callbacks — Account & App
    var onSignOut: ((GmailAccount) -> Void)?
    var onSetAsDefault: ((String) -> Void)?
    var onSetAccentColor: ((String, String) -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onShowDebug: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onNewEvent: (() -> Void)?

    @Environment(SyncProgressManager.self) private var syncProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("showDebugMenu") private var showDebugMenu = false

    @State private var labelToRename: GmailLabel?
    @State private var labelToDelete: GmailLabel?
    @State private var renameText = ""
    @State private var hoveredFolder: Folder?
    @State private var dropTargetFolder: Folder?
    @State private var dropTargetLabel: String?
    @State private var showLabelsPopover = false
    @Namespace private var modeNamespace

    var body: some View {
        Group {
            if isCollapsed {
                collapsedSidebar
                    .transition(.opacity.animation(.smooth(duration: DurationToken.quick)))
            } else {
                expandedSidebar
                    .transition(.opacity.animation(.smooth(duration: DurationToken.deliberate).delay(DurationToken.micro)))
            }
        }
        .animation(reduceMotion ? nil : VikAnimation.springDefault, value: isCollapsed)
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

    // MARK: - Expanded Sidebar

    private var expandedSidebar: some View {
        VStack(spacing: 0) {
            accountHeader
            modeSwitcher
            Divider()
                .padding(.horizontal, Spacing.sm)
            Group {
                if viewMode == .calendar {
                    calendarSidebarContent
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: OffsetToken.nudge)),
                            removal: .opacity.combined(with: .offset(y: -OffsetToken.nudge))
                        ))
                } else {
                    sidebarList
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -OffsetToken.nudge)),
                            removal: .opacity.combined(with: .offset(y: OffsetToken.nudge))
                        ))
                }
            }
            .animation(reduceMotion ? nil : VikAnimation.folderSwitch, value: viewMode)
        }
    }

    // MARK: - Mode Switcher

    private var modeSwitcher: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                modeSwitcherButton(
                    icon: "envelope.fill",
                    label: "Mail",
                    glassID: "mail",
                    isActive: viewMode == .mail
                ) {
                    onSwitchToMail()
                }
                modeSwitcherButton(
                    icon: "calendar",
                    label: "Calendar",
                    glassID: "calendar",
                    isActive: viewMode == .calendar
                ) {
                    onSwitchToCalendar()
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private func modeSwitcherButton(
        icon: String,
        label: String,
        glassID: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(VikAnimation.contentSwitch) { action() }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(Typography.captionSemibold)
            }
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xs)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.interactive(),
            in: .capsule
        )
        .glassEffectID(isActive ? "selectedMode" : glassID, in: modeNamespace)
        .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.5), trigger: isActive)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Calendar Sidebar Content

    @ViewBuilder
    private var calendarSidebarContent: some View {
        if let calendarVM = calendarViewModel {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    CalendarMiniMonthView(viewModel: calendarVM)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.top, Spacing.sm)

                    CalendarListSidebarView(
                        viewModel: calendarVM,
                        onNewEvent: { onNewEvent?() }
                    )
                }
            }
            .scrollIndicators(.hidden)
        } else {
            ContentUnavailableView(
                "Calendar Loading",
                systemImage: "calendar",
                description: Text("Sign in to view your calendars.")
            )
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Collapsed Sidebar

    private var collapsedSidebar: some View {
        VStack(spacing: 0) {
            AccountSwitcherView(
                accounts: authViewModel.accounts,
                selectedAccountID: $selectedAccountID,
                isExpanded: false,
                onSignIn: { await authViewModel.signIn() },
                isSigningIn: authViewModel.isSigningIn,
                onSignOut: onSignOut,
                onSetAsDefault: onSetAsDefault,
                onSetAccentColor: onSetAccentColor,
                onExpandSidebar: onToggleSidebar
            )
            .padding(.vertical, Spacing.sm)

            Divider()
                .padding(.horizontal, Spacing.sm)

            // Folder + label icons with glass hover
            GlassEffectContainer(spacing: 4) {
                VStack(spacing: 2) {
                    ForEach(Folder.mainFolders) { folder in
                        collapsedFolderButton(folder)
                    }
                }

                if !userLabels.isEmpty {
                    Divider()
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)

                    collapsedLabelsButton
                }
            }
            .padding(.vertical, Spacing.xs)

            Spacer(minLength: 0)

            SyncBubbleView(phase: syncProgress.phase, isCompact: true) {
                onRefresh?()
            }
            .padding(Spacing.sm)
        }
    }

    private func collapsedFolderButton(_ folder: Folder) -> some View {
        let isSelected = selectedFolder == folder
        let isHovered = hoveredFolder == folder

        return Button {
            selectedFolder = folder
            selectedInboxCategory = folder == .inbox ? .all : nil
        } label: {
            Image(systemName: folder.icon)
                .font(.system(size: 15))
                .frame(width: 34, height: 34)
                .foregroundStyle(isSelected ? .primary : isHovered ? .primary : .secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: CornerRadius.sm)
        )
        .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: isHovered)
        .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: isSelected)
        .sensoryFeedback(.selection, trigger: isSelected)
        .onHover { hovering in
            if hovering {
                hoveredFolder = folder
            } else if hoveredFolder == folder {
                hoveredFolder = nil
            }
        }
        .help(folder.rawValue)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(folder.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Collapsed Labels Popover

    private var collapsedLabelsButton: some View {
        Button {
            showLabelsPopover.toggle()
        } label: {
            Image(systemName: "tag")
                .font(.system(size: 15))
                .frame(width: 34, height: 34)
                .foregroundStyle(selectedFolder == .labels ? .primary : .secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: CornerRadius.sm)
        )
        .onHover { hovering in
            if hovering { hoveredFolder = nil }
        }
        .help("Labels")
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Labels")
        .accessibilityHint("\(userLabels.count) labels available")
        .accessibilityAddTraits(selectedFolder == .labels ? .isSelected : [])
        .popover(isPresented: $showLabelsPopover, arrowEdge: .trailing) {
            labelsPopoverContent
        }
    }

    private var labelsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Labels")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xs)

            ForEach(userLabels) { label in
                Button {
                    selectedFolder = .labels
                    selectedLabel = label
                    showLabelsPopover = false
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Circle()
                            .fill(Color(hex: label.color?.backgroundColor ?? "#888888"))
                            .frame(width: 8, height: 8)
                        Text(label.name)
                            .font(Typography.subheadRegular)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Spacing.xs)
        .frame(width: 180)
    }

    // MARK: - Account Header

    private var accountHeader: some View {
        VStack(spacing: 0) {
            AccountSwitcherView(
                accounts: authViewModel.accounts,
                selectedAccountID: $selectedAccountID,
                isExpanded: true,
                onSignIn: { await authViewModel.signIn() },
                isSigningIn: authViewModel.isSigningIn,
                onSignOut: onSignOut,
                onSetAsDefault: onSetAsDefault,
                onSetAccentColor: onSetAccentColor
            ) { }
            .padding(.vertical, Spacing.sm)
            .padding(.horizontal, Spacing.md)

            if let account = authViewModel.accounts.first(where: { $0.id == selectedAccountID }) {
                Text(account.email)
                    .font(Typography.captionRegular)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.sm)
            }

            Divider()
                .padding(.horizontal, Spacing.sm)
        }
    }

    // MARK: - Sidebar List

    private var sidebarList: some View {
        List {
            mailboxSection
            labelsSection
            if showDebugMenu {
                Section {
                    Button {
                        onShowDebug?()
                    } label: {
                        Label("Debug", systemImage: "ladybug")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Spacing.xs) {
                if viewMode == .mail && !miniAgendaEvents.isEmpty {
                    MiniAgendaWidget(
                        events: miniAgendaEvents,
                        onSelectEvent: { event in onNavigateToEvent(event) },
                        onShowCalendar: { onSwitchToCalendar() }
                    )
                    .padding(.horizontal, Spacing.sm)
                }
                SyncBubbleView(phase: syncProgress.phase) {
                    onRefresh?()
                }
                .padding(Spacing.sm)
            }
        }
        .accessibilityRotor("Folders") {
            ForEach(Folder.mainFolders) { folder in
                AccessibilityRotorEntry(folder.rawValue, id: folder.id)
            }
        }
    }

    // MARK: - Mailbox Section

    private var mailboxSection: some View {
        Section {
            ForEach(Folder.mainFolders) { folder in
                folderButton(folder: folder)
            }
        }
    }

    private func folderButton(folder: Folder) -> some View {
        let isDropTarget = dropTargetFolder == folder

        return Button {
            selectedFolder = folder
            selectedInboxCategory = folder == .inbox ? .all : nil
        } label: {
            Label {
                Text(folder.rawValue)
            } icon: {
                Image(systemName: folder.icon)
                    .frame(width: 20)
            }
        }
        .accessibilityLabel(folder.rawValue)
        .accessibilityAddTraits(selectedFolder == folder ? .isSelected : [])
        .glassEffect(
            isDropTarget ? .regular.interactive() : .identity,
            in: .rect(cornerRadius: CornerRadius.sm)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .strokeBorder(Color.accentColor.opacity(isDropTarget ? 0.4 : 0), lineWidth: 1.5)
        )
        .scaleEffect(isDropTarget ? ScaleToken.rowHover : 1.0)
        .animation(VikAnimation.springSnappy, value: isDropTarget)
        .dropDestination(for: EmailDragItem.self) { items, _ in
            for item in items {
                for msgId in item.messageIds {
                    switch folder {
                    case .trash:
                        onDropToTrash?(msgId, item.accountID)
                    case .archive:
                        onDropToArchive?(msgId, item.accountID)
                    case .spam:
                        onDropToSpam?(msgId, item.accountID)
                    default: break
                    }
                }
            }
            return true
        } isTargeted: { targeted in
            dropTargetFolder = targeted ? folder : nil
        }
        .contextMenu {
            Button {
                onRefresh?()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - Labels Section

    @ViewBuilder
    private var labelsSection: some View {
        if !userLabels.isEmpty {
            Section("Labels") {
                ForEach(userLabels) { label in
                    labelButton(label: label)
                }
            }
        }
    }

    private func labelButton(label: GmailLabel) -> some View {
        let isLabelSelected = selectedLabel?.id == label.id && selectedFolder == .labels
        let isDropTarget = dropTargetLabel == label.id
        let labelColor = Color(hex: label.color?.backgroundColor ?? "#888888")

        return Button {
            selectedFolder = .labels
            selectedLabel = label
        } label: {
            Label {
                Text(label.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Circle()
                    .fill(labelColor)
                    .frame(width: 8, height: 8)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
        }
        .fontWeight(isLabelSelected ? .medium : .regular)
        .accessibilityLabel(label.name)
        .accessibilityAddTraits(isLabelSelected ? .isSelected : [])
        .glassEffect(
            isDropTarget ? .regular.interactive() : .identity,
            in: .rect(cornerRadius: CornerRadius.sm)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .strokeBorder(Color.accentColor.opacity(isDropTarget ? 0.4 : 0), lineWidth: 1.5)
        )
        .scaleEffect(isDropTarget ? ScaleToken.rowHover : 1.0)
        .animation(VikAnimation.springSnappy, value: isDropTarget)
        .dropDestination(for: EmailDragItem.self) { items, _ in
            for item in items {
                for msgId in item.messageIds {
                    onDropToLabel?(msgId, label.id, item.accountID)
                }
            }
            return true
        } isTargeted: { targeted in
            dropTargetLabel = targeted ? label.id : nil
        }
        .contextMenu {
            Button {
                labelToRename = label
                renameText = label.name
            } label: {
                Label("Rename...", systemImage: "pencil")
            }
            Button(role: .destructive) {
                labelToDelete = label
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
