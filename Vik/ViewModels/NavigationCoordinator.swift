import Foundation

@Observable
@MainActor
final class NavigationCoordinator {

    // MARK: - Dependencies

    private let authViewModel: AuthViewModel

    // MARK: - State

    var selectedAccountID: String? {
        didSet { updateAccountProperties() }
    }
    var selectedFolder: Folder = .inbox
    var selectedInboxCategory: InboxCategory? = .all
    var selectedLabel: GmailLabel?
    var searchResetTrigger = 0
    var searchFocusTrigger = false

    // MARK: - Cached Account Properties

    /// Cached from `authViewModel` to avoid transitive observation. Updated when `selectedAccountID` changes.
    var accountID: String = ""
    /// Cached from `authViewModel` to avoid transitive observation. Updated when `selectedAccountID` changes.
    var fromAddress: String = ""

    // MARK: - Init

    init(authViewModel: AuthViewModel) {
        self.authViewModel = authViewModel
        updateAccountProperties()
    }

    // MARK: - Private

    private func updateAccountProperties() {
        accountID = selectedAccountID ?? authViewModel.primaryAccount?.id ?? ""
        fromAddress = authViewModel.accounts.first(where: { $0.id == accountID })?.email
            ?? authViewModel.primaryAccount?.email
            ?? ""
    }
}
