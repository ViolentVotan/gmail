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

    private var isMultiSelect: Bool { selectedEmailIDs.count > 1 }

    private func recomputeSortedEmails() {
        switch sortOrder {
        case .dateNewest, .unreadFirst: sortedEmails = emails
        case .dateOldest:               sortedEmails = emails.reversed()
        case .sender:                   sortedEmails = emails.sorted { $0.sender.name.localizedCaseInsensitiveCompare($1.sender.name) == .orderedAscending }
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
                actions.onSearch("")
            } else {
                searchDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    actions.onSearch(query)
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectedFolder.rawValue)
                    .font(Typography.titleLarge)
                    .foregroundStyle(.primary)

                Spacer()

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
                }

                if selectedFolder == .trash, !emails.isEmpty, let onEmptyTrash = actions.onEmptyTrash {
                    Button {
                        onEmptyTrash()
                    } label: {
                        Text("Empty Trash")
                            .destructiveActionStyle()
                    }
                    .buttonStyle(.plain)
                }

                if selectedFolder == .spam, !emails.isEmpty, let onEmptySpam = actions.onEmptySpam {
                    Button {
                        onEmptySpam()
                    } label: {
                        Text("Empty Spam")
                            .destructiveActionStyle()
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    Button { sortOrder = .dateNewest }  label: { Label("Date (Newest)",  systemImage: sortOrder == .dateNewest  ? "checkmark" : "") }
                    Button { sortOrder = .dateOldest }  label: { Label("Date (Oldest)",  systemImage: sortOrder == .dateOldest  ? "checkmark" : "") }
                    Button { sortOrder = .sender }       label: { Label("Sender",         systemImage: sortOrder == .sender      ? "checkmark" : "") }
                    Button { sortOrder = .unreadFirst } label: { Label("Unread first",   systemImage: sortOrder == .unreadFirst ? "checkmark" : "") }
                } label: {
                    HStack(spacing: 4) {
                        Text(sortOrder.label)
                            .font(Typography.subheadRegular)
                        Image(systemName: "chevron.down")
                            .font(Typography.captionSmallRegular)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassOrMaterial(in: .rect(cornerRadius: 6), interactive: true)
                }
                .buttonStyle(.plain)
            }

            SearchBarView(text: $searchText, focusTrigger: $searchFocusTrigger)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Email list

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
        } else {
            emailScrollView
        }
    }

    private var emailScrollView: some View {
        List(selection: $selectedEmailIDs) {
            ForEach(sortedEmails) { email in
                EmailRowView(
                    email: email,
                    isSelected: selectedEmailIDs.contains(email.id.uuidString),
                    accountID: accountID,
                    action: { handleTap(email: email) }
                )
                .tag(email.id.uuidString)
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

            if !emails.isEmpty && searchText.isEmpty {
                Color.clear
                    .frame(height: 1)
                    .onAppear { actions.onLoadMore() }
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

    func selectAll() {
        EmailSelectionManager.selectAll(
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

// MARK: - Skeleton Row

private struct EmailSkeletonRowView: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.tertiary.opacity(0.12))
                .frame(width: 6, height: 6)

            Circle()
                .fill(.tertiary.opacity(animate ? 0.1 : 0.2))
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.tertiary.opacity(animate ? 0.1 : 0.2))
                        .frame(width: 120, height: 10)
                    Spacer()
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.tertiary.opacity(animate ? 0.1 : 0.2))
                        .frame(width: 38, height: 9)
                }
                RoundedRectangle(cornerRadius: 3)
                    .fill(.tertiary.opacity(animate ? 0.1 : 0.2))
                    .frame(height: 9)
                    .padding(.trailing, 40)
                RoundedRectangle(cornerRadius: 3)
                    .fill(.tertiary.opacity(animate ? 0.1 : 0.2))
                    .frame(height: 8)
                    .padding(.trailing, 16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}
