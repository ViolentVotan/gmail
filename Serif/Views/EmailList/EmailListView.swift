import SwiftUI

struct EmailListView: View {
    let emails: [Email]
    let isLoading: Bool
    let accountID: String
    let actions: EmailListActions
    let searchResetTrigger: Int
    @Binding var searchFocusTrigger: Bool
    @Binding var selectedEmail: Email?
    @Binding var selectedEmailIDs: Set<String>
    @Binding var selectedFolder: Folder
    @State private var searchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var sortOrder: EmailSortOrder = .dateNewest
    @State private var selectionAnchorID: String?
    @State private var sortedEmails: [Email] = []
    @State private var cachedSections: [EmailDateSection] = []
    /// Tracks email IDs and section mode to skip expensive section rebuilds when only properties changed.
    @State private var lastEmailIDs: [UUID] = []
    @State private var lastUseDateSections = false
    @State private var isSearching = false

    private var isMultiSelect: Bool { selectedEmailIDs.count > 1 }

    private func recomputeSortedEmails() {
        switch sortOrder {
        case .dateNewest, .unreadFirst: sortedEmails = emails
        case .dateOldest:               sortedEmails = emails.reversed()
        case .sender:                   sortedEmails = emails.sorted { $0.sender.name.localizedCaseInsensitiveCompare($1.sender.name) == .orderedAscending }
        }

        // Only rebuild date sections when the email list, ordering, or section mode changed.
        // Property-only updates (read status, star toggle) reuse the existing sections
        // because SwiftUI's List diffing handles per-row updates via identity.
        let currentIDs = sortedEmails.map(\.id)
        if currentIDs != lastEmailIDs || useDateSections != lastUseDateSections {
            lastEmailIDs = currentIDs
            lastUseDateSections = useDateSections
            cachedSections = useDateSections ? Self.buildSections(from: sortedEmails) : []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider().background(.separator)
            emailListSection
            hiddenButtons
        }
        .onAppear { recomputeSortedEmails() }
        .onChange(of: emails) { _, _ in recomputeSortedEmails() }
        .task(id: "midnight-refresh") {
            // Refresh date sections at midnight so "Today"/"Yesterday" labels stay correct.
            while !Task.isCancelled {
                let calendar = Calendar.current
                guard let midnight = calendar.nextDate(
                    after: Date(),
                    matching: DateComponents(hour: 0, minute: 0, second: 0),
                    matchingPolicy: .nextTime
                ) else { break }
                try? await Task.sleep(for: .seconds(midnight.timeIntervalSinceNow))
                guard !Task.isCancelled else { break }
                recomputeSortedEmails()
            }
        }
        .onChange(of: searchResetTrigger) { _, _ in
            searchText = ""
            sortOrder = .dateNewest
        }
        .onChange(of: sortOrder) { _, newSort in
            recomputeSortedEmails()
            switch newSort {
            case .unreadFirst: actions.onSearch("is:unread")
            default:           actions.onSearch(searchText)
            }
        }
        .onChange(of: searchText) { _, query in
            searchDebounceTask?.cancel()
            if query.isEmpty {
                isSearching = false
                actions.onSearch("")
            } else {
                isSearching = true
                searchDebounceTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    actions.onSearch(query)
                    isSearching = false
                }
            }
        }
        .onChange(of: isLoading) { _, loading in
            if !loading { isSearching = false }
        }
    }

    // MARK: - Header

    private var hasFolderAction: Bool {
        switch selectedFolder {
        case .subscriptions:
            return !emails.isEmpty && actions.onUnsubscribe != nil
                && emails.contains { $0.isFromMailingList && $0.unsubscribeURL != nil }
        case .trash:
            return !emails.isEmpty && actions.onEmptyTrash != nil
        case .spam:
            return !emails.isEmpty && actions.onEmptySpam != nil
        default:
            return false
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if hasFolderAction {
                HStack {
                    Spacer()
                    folderActionButton
                }
            }

            HStack(spacing: Spacing.sm) {
                SearchBarView(text: $searchText, focusTrigger: $searchFocusTrigger)
                    .overlay(alignment: .trailing) {
                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, Spacing.xl)
                        }
                    }

                sortMenu
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.md)
    }

    @ViewBuilder
    private var folderActionButton: some View {
        if selectedFolder == .subscriptions, !emails.isEmpty, let onUnsubscribe = actions.onUnsubscribe {
            let unsubscribable = emails.filter { $0.isFromMailingList && $0.unsubscribeURL != nil }
            if !unsubscribable.isEmpty {
                Button {
                    unsubscribable.forEach { onUnsubscribe($0) }
                } label: {
                    Text("Unsubscribe All (\(unsubscribable.count))")
                        .destructiveActionStyle()
                }
                .buttonStyle(.plain)
            }
        } else if selectedFolder == .trash, !emails.isEmpty, let onEmptyTrash = actions.onEmptyTrash {
            Button {
                onEmptyTrash()
            } label: {
                Text("Empty Trash")
                    .destructiveActionStyle()
            }
            .buttonStyle(.plain)
        } else if selectedFolder == .spam, !emails.isEmpty, let onEmptySpam = actions.onEmptySpam {
            Button {
                onEmptySpam()
            } label: {
                Text("Empty Spam")
                    .destructiveActionStyle()
            }
            .buttonStyle(.plain)
        }
    }

    private var sortMenu: some View {
        Menu {
            Button { sortOrder = .dateNewest }  label: { Label("Date (Newest)",  systemImage: sortOrder == .dateNewest  ? "checkmark" : "") }
            Button { sortOrder = .dateOldest }  label: { Label("Date (Oldest)",  systemImage: sortOrder == .dateOldest  ? "checkmark" : "") }
            Button { sortOrder = .sender }       label: { Label("Sender",         systemImage: sortOrder == .sender      ? "checkmark" : "") }
            Button { sortOrder = .unreadFirst } label: { Label("Unread first",   systemImage: sortOrder == .unreadFirst ? "checkmark" : "") }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(Typography.subheadRegular)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm), interactive: true)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Email list

    @ViewBuilder
    private var emptyListState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            switch selectedFolder {
            case .inbox:
                ContentUnavailableView(
                    "You're all caught up",
                    systemImage: "checkmark.circle",
                    description: Text("No unread emails. Enjoy the moment.")
                )
            case .drafts:
                ContentUnavailableView(
                    "No Drafts",
                    systemImage: "doc.text",
                    description: Text("Drafts you create will appear here.")
                )
            case .sent:
                ContentUnavailableView(
                    "No Sent Emails",
                    systemImage: "paperplane",
                    description: Text("Emails you send will appear here.")
                )
            case .trash:
                ContentUnavailableView(
                    "Trash is Empty",
                    systemImage: "trash",
                    description: Text("Deleted emails will appear here.")
                )
            case .spam:
                ContentUnavailableView(
                    "No Spam",
                    systemImage: "exclamationmark.shield",
                    description: Text("Messages marked as spam will appear here.")
                )
            case .starred:
                ContentUnavailableView(
                    "No Starred Emails",
                    systemImage: "star",
                    description: Text("Star emails to find them here.")
                )
            case .archive:
                ContentUnavailableView(
                    "Archive is Empty",
                    systemImage: "archivebox",
                    description: Text("Archived emails will appear here.")
                )
            case .snoozed:
                ContentUnavailableView(
                    "No Snoozed Emails",
                    systemImage: "moon.zzz",
                    description: Text("Snoozed emails will reappear when their time is up.")
                )
            case .subscriptions:
                ContentUnavailableView(
                    "No Subscriptions",
                    systemImage: "newspaper",
                    description: Text("Mailing list emails will appear here.")
                )
            default:
                ContentUnavailableView(
                    "No Emails",
                    systemImage: "tray",
                    description: Text("This folder is empty.")
                )
            }
        }
    }

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
            .scrollEdgeEffectStyle(.hard, for: .top)
        } else if !isLoading && emails.isEmpty {
            emptyListState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emailScrollView
        }
    }

    // MARK: - Date grouping

    private var useDateSections: Bool {
        sortOrder == .dateNewest || sortOrder == .dateOldest
    }

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static func buildSections(from emails: [Email]) -> [EmailDateSection] {
        var sections: [EmailDateSection] = []
        var currentTitle = ""
        var currentEmails: [Email] = []
        let calendar = Calendar.current
        let now = Date()
        let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        let lastWeekStart: Date? = {
            guard let thisWeekStart else { return nil }
            return calendar.date(byAdding: .day, value: -7, to: thisWeekStart)
        }()

        for email in emails {
            let title = dateGroupTitle(for: email.date, calendar: calendar, now: now, thisWeekStart: thisWeekStart, lastWeekStart: lastWeekStart)
            if title != currentTitle {
                if !currentEmails.isEmpty {
                    sections.append(EmailDateSection(title: currentTitle, emails: currentEmails))
                }
                currentTitle = title
                currentEmails = [email]
            } else {
                currentEmails.append(email)
            }
        }
        if !currentEmails.isEmpty {
            sections.append(EmailDateSection(title: currentTitle, emails: currentEmails))
        }
        return sections
    }

    private static func dateGroupTitle(
        for date: Date,
        calendar: Calendar,
        now: Date,
        thisWeekStart: Date?,
        lastWeekStart: Date?
    ) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        if let thisWeekStart, date >= thisWeekStart {
            return "This Week"
        }

        if let lastWeekStart, date >= lastWeekStart {
            return "Last Week"
        }

        return monthYearFormatter.string(from: date)
    }

    // MARK: - Email row builder

    @ViewBuilder
    private func emailRow(for email: Email) -> some View {
        EmailRowView(
            email: email,
            isSelected: selectedEmailIDs.contains(email.id.uuidString),
            accountID: accountID,
            action: { handleTap(email: email) }
        )
        .equatable()
        .tag(email.id.uuidString)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if selectedFolder != .archive {
                Button {
                    actions.onArchive?(email)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.gray)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if selectedFolder != .trash {
                Button(role: .destructive) {
                    actions.onDelete?(email)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            EmailContextMenu(
                email: email,
                selectedFolder: selectedFolder,
                onArchive: actions.onArchive,
                onDelete: actions.onDelete,
                onToggleStar: actions.onToggleStar,
                onMarkUnread: actions.onMarkUnread,
                onMarkSpam: actions.onMarkSpam,
                onUnsubscribe: actions.onUnsubscribe,
                onMoveToInbox: actions.onMoveToInbox,
                onDeletePermanently: actions.onDeletePermanently,
                onMarkNotSpam: actions.onMarkNotSpam,
                onSnooze: actions.onSnooze,
                onCreateFilter: nil,
                onReply: actions.onReply,
                onReplyAll: actions.onReplyAll,
                onForward: actions.onForward
            )
        }
    }

    // MARK: - Scroll view

    private var emailScrollView: some View {
        List(selection: $selectedEmailIDs) {
            if useDateSections {
                ForEach(cachedSections) { section in
                    Section {
                        ForEach(section.emails) { email in
                            emailRow(for: email)
                        }
                    } header: {
                        HStack(spacing: Spacing.sm) {
                            Text(section.title)
                                .font(Typography.caption)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                            VStack { Divider() }
                        }
                    }
                }
            } else {
                ForEach(sortedEmails) { email in
                    emailRow(for: email)
                }
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
            await actions.onRefresh?()
        }
        .focusable()
        .focusEffectDisabled(true)
        .onKeyPress(.upArrow) { navigateToPrevious(); return .handled }
        .onKeyPress(.downArrow) { navigateToNext(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "e")) { _ in handleKeyE() }
        .onKeyPress(characters: CharacterSet(charactersIn: "s")) { _ in handleKeyS() }
        .onKeyPress(characters: CharacterSet(charactersIn: "u")) { _ in handleKeyU() }
        .onKeyPress(characters: CharacterSet(charactersIn: "r")) { _ in handleKeyR() }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .accessibilityRotor("Unread Emails") {
            ForEach(emails.filter { !$0.isRead }) { email in
                AccessibilityRotorEntry(email.subject, id: email.id)
            }
        }
        .accessibilityRotor("Starred") {
            ForEach(emails.filter { $0.isStarred }) { email in
                AccessibilityRotorEntry(email.subject, id: email.id)
            }
        }
        .accessibilityRotor("Has Attachments") {
            ForEach(emails.filter { $0.hasAttachments }) { email in
                AccessibilityRotorEntry(email.subject, id: email.id)
            }
        }
    }

    // MARK: - Hidden buttons

    private var hiddenButtons: some View {
        Group {
            Button("") {
                if isMultiSelect { actions.onBulkDelete?() }
                else if let email = selectedEmail { actions.onDelete?(email) }
            }
            .keyboardShortcut(.delete, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    // MARK: - Key handlers

    private func handleKeyE() -> KeyPress.Result {
        if isMultiSelect { actions.onBulkArchive?() }
        else if let email = selectedEmail { actions.onArchive?(email) }
        return .handled
    }

    private func handleKeyS() -> KeyPress.Result {
        if isMultiSelect { actions.onBulkToggleStar?() }
        else if let email = selectedEmail { actions.onToggleStar?(email) }
        return .handled
    }

    private func handleKeyU() -> KeyPress.Result {
        if isMultiSelect { actions.onBulkMarkUnread?() }
        else if let email = selectedEmail { actions.onMarkUnread?(email) }
        return .handled
    }

    private func handleKeyR() -> KeyPress.Result {
        if isMultiSelect { actions.onBulkMarkRead?() }
        return .handled
    }

    // MARK: - Selection (delegated to EmailSelectionManager)

    private func handleTap(email: Email) {
        EmailSelectionManager.handleTap(
            email: email,
            sortedEmails: sortedEmails,
            selectedEmailIDs: &selectedEmailIDs,
            selectedEmail: &selectedEmail,
            selectionAnchorID: &selectionAnchorID
        )
    }

    private func navigateToPrevious() {
        EmailSelectionManager.navigateToPrevious(
            sortedEmails: sortedEmails,
            selectedEmailIDs: &selectedEmailIDs,
            selectedEmail: &selectedEmail,
            selectionAnchorID: &selectionAnchorID
        )
    }

    private func navigateToNext() {
        EmailSelectionManager.navigateToNext(
            sortedEmails: sortedEmails,
            selectedEmailIDs: &selectedEmailIDs,
            selectedEmail: &selectedEmail,
            selectionAnchorID: &selectionAnchorID
        )
    }
}

// MARK: - Sort Order

enum EmailSortOrder {
    case dateNewest, dateOldest, sender, unreadFirst

    var label: String {
        switch self {
        case .dateNewest:  return "Recent"
        case .dateOldest:  return "Oldest"
        case .sender:      return "Sender"
        case .unreadFirst: return "Unread"
        }
    }
}

// MARK: - Date Section

private struct EmailDateSection: Identifiable {
    let title: String
    let emails: [Email]
    var id: String { title }
}

// MARK: - Skeleton Row

private struct EmailSkeletonRowView: View {
    var body: some View {
        PhaseAnimator([false, true]) { phase in
            let shimmerOpacity = phase ? 0.1 : 0.2
            HStack(spacing: 12) {
                Circle()
                    .fill(.tertiary.opacity(0.12))
                    .frame(width: 6, height: 6)

                Circle()
                    .fill(.tertiary.opacity(shimmerOpacity))
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.tertiary.opacity(shimmerOpacity))
                            .frame(width: 120, height: 10)
                        Spacer()
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.tertiary.opacity(shimmerOpacity))
                            .frame(width: 38, height: 9)
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.tertiary.opacity(shimmerOpacity))
                        .frame(height: 9)
                        .padding(.trailing, 40)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.tertiary.opacity(shimmerOpacity))
                        .frame(height: 8)
                        .padding(.trailing, Spacing.lg)
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .padding(.horizontal, Spacing.sm)
            .drawingGroup(opaque: false)
        } animation: { _ in
            .easeInOut(duration: 0.9)
        }
    }
}
