import SwiftUI

@Observable
@MainActor
final class SelectionCoordinator {

    // MARK: - Dependencies

    private let mailboxViewModel: MailboxViewModel
    var accountID: String = ""
    var mailDatabase: MailDatabase?

    // MARK: - State

    var selectedEmail: Email?
    var selectedEmailIDs: Set<String> = [] {
        didSet { recomputeSelectedEmails() }
    }
    /// Direction of the last email selection for directional detail pane transitions.
    var selectionDirection: Edge = .bottom
    private(set) var displayedEmails: [Email] = []
    /// Derived from `displayedEmails` filtered by `selectedEmailIDs`. Single source of truth
    /// for both ListPaneView and the detail pane views (avoids duplicate @State + transient disagreement).
    private(set) var selectedEmails: [Email] = []

    // MARK: - Private State

    @ObservationIgnored private var emailIndexMap: [UUID: Int] = [:]
    @ObservationIgnored private var markReadTask: Task<Void, Never>?
    @ObservationIgnored private var lastFolder: Folder = .inbox

    // MARK: - Init

    init(mailboxViewModel: MailboxViewModel) {
        self.mailboxViewModel = mailboxViewModel
    }

    isolated deinit {
        markReadTask?.cancel()
    }

    // MARK: - Actions

    func selectNext(_ email: Email?) {
        if let email {
            selectedEmail = email
        } else {
            // Auto-advance to adjacent email when current is removed (archive/delete/snooze/etc.)
            guard let current = selectedEmail,
                  let idx = emailIndexMap[current.id] else {
                selectedEmail = nil
                return
            }
            if idx + 1 < displayedEmails.count {
                let next = displayedEmails[idx + 1]
                selectionDirection = .bottom
                selectedEmail = next
                selectedEmailIDs = [next.id.uuidString]
            } else if idx > 0 {
                let prev = displayedEmails[idx - 1]
                selectionDirection = .top
                selectedEmail = prev
                selectedEmailIDs = [prev.id.uuidString]
            } else {
                selectedEmail = nil
                selectedEmailIDs = []
            }
        }
    }

    /// Navigate to the previous email in the displayed list.
    func selectPrevious() {
        guard let current = selectedEmail,
              let idx = emailIndexMap[current.id],
              idx > 0 else { return }
        selectionDirection = .top
        let prev = displayedEmails[idx - 1]
        selectedEmail = prev
        selectedEmailIDs = [prev.id.uuidString]
    }

    /// Navigate to the next email in the displayed list.
    func selectNextEmail() {
        guard let current = selectedEmail,
              let idx = emailIndexMap[current.id],
              idx < displayedEmails.count - 1 else { return }
        selectionDirection = .bottom
        let next = displayedEmails[idx + 1]
        selectedEmail = next
        selectedEmailIDs = [next.id.uuidString]
    }

    func clearSelection() {
        selectedEmail = nil
        selectedEmailIDs = []
    }

    func deselectAll() {
        selectedEmailIDs = []
    }

    func selectAllEmails() {
        selectedEmailIDs = Set(displayedEmails.map { $0.id.uuidString })
        selectedEmail = nil
    }

    // MARK: - Displayed Emails

    func updateDisplayedEmails(
        folder: Folder,
        mailStore: MailStore,
        mailboxViewModel: MailboxViewModel,
        cachedSnoozedEmails: [Email],
        cachedScheduledEmails: [Email]
    ) {
        let newEmails: [Email]
        switch folder {
        case .drafts:        newEmails = mailStore.emails(for: .drafts)
        case .subscriptions: newEmails = SubscriptionsStore.shared.entries
        case .snoozed:       newEmails = cachedSnoozedEmails
        case .scheduled:     newEmails = cachedScheduledEmails
        default:
            newEmails = mailboxViewModel.priorityFilterEnabled
                ? mailboxViewModel.emails.filter { $0.gmailLabelIDs.contains(GmailSystemLabel.important) }
                : mailboxViewModel.emails
        }
        guard folder != lastFolder || newEmails != displayedEmails else { return }
        lastFolder = folder
        displayedEmails = newEmails
        // Rebuild O(1) lookup index for arrow-key navigation.
        emailIndexMap = Dictionary(uniqueKeysWithValues: displayedEmails.enumerated().map { ($1.id, $0) })
        recomputeSelectedEmails()
        // Keep selectedEmail fresh: replace with the updated version from the
        // new list so the detail pane reflects property changes (read, star, labels).
        if let selected = selectedEmail,
           let fresh = displayedEmails.first(where: { $0.id == selected.id }),
           fresh != selected {
            selectedEmail = fresh
        }
    }

    /// Recomputes `selectedEmails` from `displayedEmails` filtered by `selectedEmailIDs`.
    private func recomputeSelectedEmails() {
        let new = displayedEmails.filter { selectedEmailIDs.contains($0.id.uuidString) }
        if new.map(\.id) != selectedEmails.map(\.id) {
            selectedEmails = new
        }
    }

    /// O(1) index lookup for a given email ID.
    func emailIndex(for id: UUID) -> Int? {
        emailIndexMap[id]
    }

    // MARK: - Email Change Handler

    func handleSelectedEmailChange(_ email: Email?) {
        guard let email else { return }
        EmailContentPrefetcher.shared.prefetch(
            email: email,
            accountID: accountID,
            mailDatabase: mailDatabase
        )
        Task { await SpotlightIndexer.shared.indexEmail(email) }
        guard let msgID = email.gmailMessageID, !email.isRead else { return }
        markReadTask?.cancel()
        markReadTask = Task { [weak self] in
            guard let self else { return }
            await self.mailboxViewModel.labelMutations.markAsRead(msgID)
            guard !Task.isCancelled else { return }
            await self.mailboxViewModel.loadCategoryUnreadCounts()
        }
    }
}
