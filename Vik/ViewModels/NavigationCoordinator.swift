import Foundation

@Observable
@MainActor
final class NavigationCoordinator {

    // MARK: - Dependencies

    private let authViewModel: AuthViewModel

    // MARK: - State

    var selectedAccountID: String?
    var selectedFolder: Folder = .inbox
    var selectedInboxCategory: InboxCategory? = .all
    var selectedLabel: GmailLabel?
    var searchResetTrigger = 0
    var searchFocusTrigger = false

    // MARK: - Init

    init(authViewModel: AuthViewModel) {
        self.authViewModel = authViewModel
    }

    // MARK: - Computed Properties

    var accountID: String {
        selectedAccountID ?? authViewModel.primaryAccount?.id ?? ""
    }

    var fromAddress: String {
        authViewModel.accounts.first(where: { $0.id == selectedAccountID })?.email
            ?? authViewModel.primaryAccount?.email
            ?? ""
    }
}
