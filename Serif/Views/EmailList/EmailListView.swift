import SwiftUI

struct EmailListView: View {
    let emails: [Email]
    let isLoading: Bool
    let accountID: String
    let onLoadMore: () -> Void
    let onSearch: (String) -> Void
    let onArchive: ((Email) -> Void)?
    let onDelete: ((Email) -> Void)?
    let onToggleStar: ((Email) -> Void)?
    let onMarkUnread: ((Email) -> Void)?
    let onMarkSpam: ((Email) -> Void)?
    let onUnsubscribe: ((Email) -> Void)?
    let onMoveToInbox: ((Email) -> Void)?
    let onDeletePermanently: ((Email) -> Void)?
    let onMarkNotSpam: ((Email) -> Void)?
    let onSnooze: ((Email, Date) -> Void)?
    let onEmptyTrash: (() -> Void)?
    let onEmptySpam: (() -> Void)?
    let onBulkArchive: (() -> Void)?
    let onBulkDelete: (() -> Void)?
    let onBulkMarkUnread: (() -> Void)?
    let onBulkMarkRead: (() -> Void)?
    let onBulkToggleStar: (() -> Void)?
    let onRefresh: (() async -> Void)?
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
            case .unreadFirst: onSearch("is:unread")
            default:           onSearch(searchText)
            }
        }
        .onChange(of: searchText) { _, query in
            searchDebounceTask?.cancel()
            if query.isEmpty {
                onSearch("")
            } else {
                searchDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    onSearch(query)
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectedFolder.rawValue)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)

                Spacer()

                if selectedFolder == .subscriptions, !emails.isEmpty, let onUnsubscribe {
                    let unsubscribable = emails.filter { $0.isFromMailingList && $0.unsubscribeURL != nil }
                    if !unsubscribable.isEmpty {
                        Button {
                            unsubscribable.forEach { onUnsubscribe($0) }
                        } label: {
                            Text("Unsubscribe All (\(unsubscribable.count))")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if selectedFolder == .trash, !emails.isEmpty, let onEmptyTrash {
                    Button {
                        onEmptyTrash()
                    } label: {
                        Text("Empty Trash")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                if selectedFolder == .spam, !emails.isEmpty, let onEmptySpam {
                    Button {
                        onEmptySpam()
                    } label: {
                        Text("Empty Spam")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(6)
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
                            .font(.subheadline)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial)
                    .cornerRadius(6)
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
            .scrollEdgeEffectStyle(.automatic, for: .all)
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
                        onMarkNotSpam: onMarkNotSpam,
                        onSnooze: onSnooze,
                        onCreateFilter: nil
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
        .scrollEdgeEffectStyle(.automatic, for: .all)
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
                if isMultiSelect { onBulkDelete?() }
                else if let email = selectedEmail { onDelete?(email) }
            }
            .keyboardShortcut(.delete, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    // MARK: - Key handlers

    private func handleKeyE() -> KeyPress.Result {
        if isMultiSelect { onBulkArchive?() }
        else if let email = selectedEmail { onArchive?(email) }
        return .handled
    }

    private func handleKeyS() -> KeyPress.Result {
        if isMultiSelect { onBulkToggleStar?() }
        else if let email = selectedEmail { onToggleStar?(email) }
        return .handled
    }

    private func handleKeyU() -> KeyPress.Result {
        if isMultiSelect { onBulkMarkUnread?() }
        else if let email = selectedEmail { onMarkUnread?(email) }
        return .handled
    }

    private func handleKeyR() -> KeyPress.Result {
        if isMultiSelect { onBulkMarkRead?() }
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
