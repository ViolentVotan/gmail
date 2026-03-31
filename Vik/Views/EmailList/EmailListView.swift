import SwiftUI

// MARK: - EmailListSortModel

/// Owns sort/section/accessibility computation off the view's body.
@Observable @MainActor
private final class EmailListSortModel {

    struct AccessibilityCache {
        var unreadEmails: [Email] = []
        var starredEmails: [Email] = []
        var emailsWithAttachments: [Email] = []
        var hasFolderAction = false
        var unsubscribableEmails: [Email] = []
    }

    private(set) var sortedEmails: [Email] = []
    private(set) var cachedSections: [EmailDateSection] = []
    private(set) var accessibilityCache = AccessibilityCache()

    private var lastEmailIDs: [UUID] = []
    private var lastUseDateSections = false

    func recompute(
        emails: [Email],
        sortOrder: EmailSortOrder,
        folder: Folder,
        hasUnsubscribe: Bool,
        hasEmptyTrash: Bool,
        hasEmptySpam: Bool
    ) {
        let useSections = sortOrder == .dateNewest || sortOrder == .dateOldest

        switch sortOrder {
        case .dateNewest, .unreadFirst: sortedEmails = emails
        case .dateOldest:               sortedEmails = emails.reversed()
        case .sender:
            let snapshot = emails
            Task {
                let sorted = await Task.detached {
                    snapshot.sorted { $0.sender.name.localizedCaseInsensitiveCompare($1.sender.name) == .orderedAscending }
                }.value
                sortedEmails = sorted
                applyPostSortUpdates(
                    sortedEmails: sorted, sourceEmails: snapshot,
                    folder: folder, useSections: useSections,
                    hasUnsubscribe: hasUnsubscribe, hasEmptyTrash: hasEmptyTrash, hasEmptySpam: hasEmptySpam
                )
            }
            return
        }

        applyPostSortUpdates(
            sortedEmails: sortedEmails, sourceEmails: emails,
            folder: folder, useSections: useSections,
            hasUnsubscribe: hasUnsubscribe, hasEmptyTrash: hasEmptyTrash, hasEmptySpam: hasEmptySpam
        )
    }

    private func applyPostSortUpdates(
        sortedEmails: [Email],
        sourceEmails: [Email],
        folder: Folder,
        useSections: Bool,
        hasUnsubscribe: Bool,
        hasEmptyTrash: Bool,
        hasEmptySpam: Bool
    ) {
        var currentIDs: [Email.ID] = []
        currentIDs.reserveCapacity(sortedEmails.count)
        var newCache = AccessibilityCache()
        newCache.unreadEmails.reserveCapacity(sortedEmails.count)
        newCache.starredEmails.reserveCapacity(sortedEmails.count / 4)
        newCache.emailsWithAttachments.reserveCapacity(sortedEmails.count / 4)

        for email in sortedEmails {
            currentIDs.append(email.id)
            if !email.isRead { newCache.unreadEmails.append(email) }
            if email.isStarred { newCache.starredEmails.append(email) }
            if email.hasAttachments { newCache.emailsWithAttachments.append(email) }
        }

        if currentIDs != lastEmailIDs || useSections != lastUseDateSections {
            lastEmailIDs = currentIDs
            lastUseDateSections = useSections
            cachedSections = useSections ? EmailListSortModel.buildSections(from: sortedEmails) : []
        }

        switch folder {
        case .subscriptions:
            newCache.unsubscribableEmails = sourceEmails.filter { $0.isFromMailingList && $0.unsubscribeURL != nil }
            newCache.hasFolderAction = !sourceEmails.isEmpty && hasUnsubscribe && !newCache.unsubscribableEmails.isEmpty
        case .trash:
            newCache.hasFolderAction = !sourceEmails.isEmpty && hasEmptyTrash
        case .spam:
            newCache.hasFolderAction = !sourceEmails.isEmpty && hasEmptySpam
        default:
            break
        }
        accessibilityCache = newCache
    }

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

        return date.formattedMonthYear
    }
}

// MARK: - EmailListView

struct EmailListView: View {
    let emails: [Email]
    let isLoading: Bool
    let accountID: String
    let actions: EmailListActions
    let searchResetTrigger: Int
    let hasMoreEmails: Bool
    let isLoadingMore: Bool
    @Binding var searchFocusTrigger: Bool
    @Binding var selectedEmail: Email?
    @Binding var selectedEmailIDs: Set<String>
    @Binding var selectedFolder: Folder
    @Binding var priorityFilterOn: Bool
    var showPriorityFilter = false
    @State private var searchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var sortOrder: EmailSortOrder = .dateNewest
    @State private var selectionAnchorID: String?
    @State private var sortModel = EmailListSortModel()
    @State private var isSearching = false
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @AppStorage("emailDensity") private var density = "comfortable"
    @State private var hoverActions = EmailHoverActions()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedEmailIDs: Set<String> = []
    @State private var showDeletePermanentlyConfirmation = false
    @State private var showSpamConfirmation = false
    @State private var showUnsubscribeAllConfirmation = false
    @State private var showEmptyTrashConfirmation = false
    @State private var showEmptySpamConfirmation = false
    @State private var pendingConfirmationEmail: Email?

    private var isMultiSelect: Bool { selectedEmailIDs.count > 1 }

    private func recomputeSortedEmails() {
        sortModel.recompute(
            emails: emails,
            sortOrder: sortOrder,
            folder: selectedFolder,
            hasUnsubscribe: actions.onUnsubscribe != nil,
            hasEmptyTrash: actions.onEmptyTrash != nil,
            hasEmptySpam: actions.onEmptySpam != nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
                .padding(.horizontal, Spacing.xl)
            emailListSection
            hiddenButtons
        }
        .confirmationDialog("Permanently delete this email? This cannot be undone.", isPresented: $showDeletePermanentlyConfirmation, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                guard let target = pendingConfirmationEmail else { return }
                actions.onDeletePermanently?(target)
            }
        }
        .confirmationDialog("Report this email as spam?", isPresented: $showSpamConfirmation, titleVisibility: .visible) {
            Button("Report as Spam", role: .destructive) {
                guard let target = pendingConfirmationEmail else { return }
                actions.onMarkSpam?(target)
            }
        }
        .confirmationDialog("Unsubscribe from \(sortModel.accessibilityCache.unsubscribableEmails.count) senders? This will send unsubscribe requests.", isPresented: $showUnsubscribeAllConfirmation, titleVisibility: .visible) {
            Button("Unsubscribe All", role: .destructive) {
                guard let onUnsubscribe = actions.onUnsubscribe else { return }
                sortModel.accessibilityCache.unsubscribableEmails.forEach { onUnsubscribe($0) }
            }
        }
        .task { recomputeSortedEmails() }
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

    private var hasFolderAction: Bool { sortModel.accessibilityCache.hasFolderAction }

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
                                .padding(.trailing, searchText.isEmpty ? Spacing.xl : 44)
                        }
                    }

                if showPriorityFilter {
                    priorityButton
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
        if selectedFolder == .subscriptions, !sortModel.accessibilityCache.unsubscribableEmails.isEmpty, actions.onUnsubscribe != nil {
            Button {
                showUnsubscribeAllConfirmation = true
            } label: {
                Text("Unsubscribe All (\(sortModel.accessibilityCache.unsubscribableEmails.count))")
                    .destructiveActionStyle()
            }
            .buttonStyle(.plain)
        } else if selectedFolder == .trash, !emails.isEmpty, actions.onEmptyTrash != nil {
            Button {
                showEmptyTrashConfirmation = true
            } label: {
                Text("Empty Trash")
                    .destructiveActionStyle()
            }
            .buttonStyle(.plain)
            .confirmationDialog("Empty Trash?", isPresented: $showEmptyTrashConfirmation) {
                Button("Empty Trash", role: .destructive) {
                    actions.onEmptyTrash?()
                }
            } message: {
                Text("All messages in Trash will be permanently deleted. This action cannot be undone.")
            }
        } else if selectedFolder == .spam, !emails.isEmpty, actions.onEmptySpam != nil {
            Button {
                showEmptySpamConfirmation = true
            } label: {
                Text("Empty Spam")
                    .destructiveActionStyle()
            }
            .buttonStyle(.plain)
            .confirmationDialog("Empty Spam?", isPresented: $showEmptySpamConfirmation) {
                Button("Empty Spam", role: .destructive) {
                    actions.onEmptySpam?()
                }
            } message: {
                Text("All messages in Spam will be permanently deleted. This action cannot be undone.")
            }
        }
    }

    private var priorityButton: some View {
        Button {
            priorityFilterOn.toggle()
        } label: {
            Image(systemName: priorityFilterOn ? "flag.fill" : "flag")
                .font(Typography.subheadRegular)
                .foregroundStyle(priorityFilterOn ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
                .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm), interactive: true)
        }
        .buttonStyle(.plain)
        .help("Show only important emails")
        .accessibilityLabel(priorityFilterOn ? "Priority filter on" : "Priority filter off")
        .accessibilityHint("Toggle to show only important emails")
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
        .accessibilityLabel("Sort emails")
        .accessibilityValue(sortOrder.label)
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
                    description: Text("Your inbox is empty.")
                )
            case .drafts:
                ContentUnavailableView {
                    Label("No Drafts", systemImage: "doc.text")
                } description: {
                    Text("Drafts you create will appear here.")
                } actions: {
                    if let onCompose = actions.onCompose {
                        Button("Compose") { onCompose() }
                            .buttonStyle(.bordered)
                    }
                }
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
                    description: Text("Star emails to find them quickly.")
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
                        .accessibilityHidden(true)
                }
            }
            .listStyle(.plain)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .transition(.opacity)
        } else if !isLoading && emails.isEmpty {
            emptyListState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
        } else {
            emailScrollView
                .transition(.opacity)
        }
    }

    // MARK: - Date grouping

    private var useDateSections: Bool {
        sortOrder == .dateNewest || sortOrder == .dateOldest
    }

    // MARK: - Email row builder

    @ViewBuilder
    private func emailRow(for email: Email, entranceIndex: Int = 0) -> some View {
        let emailID = email.id.uuidString
        EmailRowView(
            email: email,
            isSelected: selectedEmailIDs.contains(emailID),
            accountID: accountID,
            selectedFolder: selectedFolder,
            isMultiSelect: selectedEmailIDs.count > 1,
            density: density,
            action: { handleTap(email: email) },
            entranceIndex: entranceIndex,
            hasAlreadyAnimated: animatedEmailIDs.contains(emailID),
            onFirstAppear: { animatedEmailIDs.insert(emailID) }
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
                onMarkRead: actions.onMarkRead,
                onMarkUnread: actions.onMarkUnread,
                onMarkSpam: actions.onMarkSpam != nil ? { target in
                    pendingConfirmationEmail = target
                    showSpamConfirmation = true
                } : nil,
                onUnsubscribe: actions.onUnsubscribe,
                onMoveToInbox: actions.onMoveToInbox,
                onDeletePermanently: actions.onDeletePermanently != nil ? { target in
                    pendingConfirmationEmail = target
                    showDeletePermanentlyConfirmation = true
                } : nil,
                onMarkNotSpam: actions.onMarkNotSpam,
                onSnooze: actions.onSnooze,
                onCreateFilter: actions.onCreateFilter,
                onUnsnooze: actions.onUnsnooze,
                onReply: actions.onReply,
                onReplyAll: actions.onReplyAll,
                onForward: actions.onForward
            )
        }
        .accessibilityAction(named: "Archive") {
            guard selectedFolder != .archive else { return }
            actions.onArchive?(email)
        }
        .accessibilityAction(named: "Delete") {
            guard selectedFolder != .trash else { return }
            actions.onDelete?(email)
        }
        .accessibilityAction(named: email.isStarred ? "Unstar" : "Star") {
            actions.onToggleStar?(email)
        }
        .accessibilityAction(named: email.isRead ? "Mark Unread" : "Mark Read") {
            if email.isRead {
                actions.onMarkUnread?(email)
            } else {
                actions.onMarkRead?(email)
            }
        }
        .accessibilityAction(named: "Snooze until Tomorrow") {
            guard ![Folder.snoozed, .trash, .sent, .drafts, .spam, .scheduled].contains(selectedFolder) else { return }
            actions.onSnooze?(email, SnoozePreset.tomorrowMorning)
        }
    }

    // MARK: - Scroll view

    private func syncHoverActions() {
        hoverActions.onArchive = actions.onArchive
        hoverActions.onDelete = actions.onDelete
        hoverActions.onSnooze = actions.onSnooze
        hoverActions.onMarkRead = actions.onMarkRead
        hoverActions.onMarkUnread = actions.onMarkUnread
    }

    private var emailScrollView: some View {
        List(selection: $selectedEmailIDs) {
            if useDateSections {
                ForEach(sortModel.cachedSections) { section in
                    Section {
                        ForEach(section.emails) { email in
                            emailRow(for: email)
                        }
                    } header: {
                        Text(section.title)
                            .font(Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .padding(.top, Spacing.lg)
                            .padding(.bottom, Spacing.xs)
                    }
                }
            } else {
                ForEach(sortModel.sortedEmails) { email in
                    emailRow(for: email)
                }
            }

            if isLoading && !emails.isEmpty {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.sm)
                    .listRowSeparator(.hidden)
            }

            if hasMoreEmails && !isLoadingMore {
                Color.clear
                    .frame(height: 1)
                    .onAppear { actions.onLoadMore?() }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .environment(hoverActions)
        .scrollPosition($scrollPosition)
        .onAppear { syncHoverActions() }
        .onChange(of: accountID) { syncHoverActions() }
        .onChange(of: selectedFolder) {
            syncHoverActions()
            animatedEmailIDs.removeAll()
            withAnimation(reduceMotion ? nil : VikAnimation.folderSwitch) {
                scrollPosition.scrollTo(edge: .top)
            }
        }
        .refreshable {
            await actions.onRefresh?()
        }
        .focusable()
        .onKeyPress(.upArrow) { navigateToPrevious(); return .handled }
        .onKeyPress(.downArrow) { navigateToNext(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "e")) { _ in handleKeyE() }
        .onKeyPress(characters: CharacterSet(charactersIn: "s")) { _ in handleKeyS() }
        .onKeyPress(characters: CharacterSet(charactersIn: "u")) { _ in handleKeyU() }
        .onKeyPress(characters: CharacterSet(charactersIn: "r")) { _ in handleKeyR() }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .accessibilityRotor("Unread Emails") {
            ForEach(sortModel.accessibilityCache.unreadEmails) { email in
                AccessibilityRotorEntry(email.subject, id: email.id)
            }
        }
        .accessibilityRotor("Starred") {
            ForEach(sortModel.accessibilityCache.starredEmails) { email in
                AccessibilityRotorEntry(email.subject, id: email.id)
            }
        }
        .accessibilityRotor("Has Attachments") {
            ForEach(sortModel.accessibilityCache.emailsWithAttachments) { email in
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
        .accessibilityHidden(true)
    }

    // MARK: - Key handlers

    private func handleKeyE() -> KeyPress.Result {
        if isMultiSelect { actions.onBulkArchive?(); return .handled }
        else if let email = selectedEmail { actions.onArchive?(email); return .handled }
        return .ignored
    }

    private func handleKeyS() -> KeyPress.Result {
        if isMultiSelect { actions.onBulkToggleStar?(); return .handled }
        else if let email = selectedEmail { actions.onToggleStar?(email); return .handled }
        return .ignored
    }

    private func handleKeyU() -> KeyPress.Result {
        if isMultiSelect { actions.onBulkMarkUnread?(); return .handled }
        else if let email = selectedEmail { actions.onMarkUnread?(email); return .handled }
        return .ignored
    }

    private func handleKeyR() -> KeyPress.Result {
        if isMultiSelect { actions.onBulkMarkRead?(); return .handled }
        else if let email = selectedEmail { actions.onMarkRead?(email); return .handled }
        return .ignored
    }

    // MARK: - Selection (delegated to EmailSelectionManager)

    private func handleTap(email: Email) {
        EmailSelectionManager.handleTap(
            email: email,
            sortedEmails: sortModel.sortedEmails,
            selectedEmailIDs: &selectedEmailIDs,
            selectedEmail: &selectedEmail,
            selectionAnchorID: &selectionAnchorID
        )
    }

    private func navigateToPrevious() {
        EmailSelectionManager.navigateToPrevious(
            sortedEmails: sortModel.sortedEmails,
            selectedEmailIDs: &selectedEmailIDs,
            selectedEmail: &selectedEmail,
            selectionAnchorID: &selectionAnchorID
        )
    }

    private func navigateToNext() {
        EmailSelectionManager.navigateToNext(
            sortedEmails: sortModel.sortedEmails,
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
    @State private var shimmerPhase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.tertiary.opacity(OpacityToken.tag))
                .frame(width: 6, height: 6)

            Circle()
                .fill(.tertiary.opacity(OpacityToken.highlight))
                .frame(width: 36, height: 36)
                .overlay {
                    shimmerOverlay
                        .clipShape(Circle())
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    shimmerRect(width: 120, height: 10)
                    Spacer()
                    shimmerRect(width: 38, height: 9)
                }
                shimmerRect(height: 9)
                    .padding(.trailing, 40)
                shimmerRect(height: 8)
                    .padding(.trailing, Spacing.lg)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.sm)
        .task {
            guard !reduceMotion else { return }
            withAnimation(VikAnimation.shimmer) {
                shimmerPhase = 1
            }
        }
    }

    private func shimmerRect(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: CornerRadius.xxs)
            .fill(.tertiary.opacity(OpacityToken.highlight))
            .frame(width: width, height: height)
            .overlay {
                shimmerOverlay
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxs))
            }
    }

    private var shimmerOverlay: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: max(0, shimmerPhase - 0.2)),
                .init(color: ShimmerColor.highlight.opacity(OpacityToken.hoverFill), location: shimmerPhase),
                .init(color: .clear, location: min(1, shimmerPhase + 0.2))
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .containerRelativeFrame(.horizontal)
    }
}
