import Foundation

@Observable @MainActor
final class FiltersViewModel {
    var filters: [GmailFilter] = []
    var isLoading = false
    var error: String?

    private let accountID: String

    init(accountID: String) {
        self.accountID = accountID
    }

    func loadFilters() async {
        isLoading = true
        defer { isLoading = false }
        do {
            filters = try await GmailFilterService.shared.listFilters(accountID: accountID)
        } catch {
            filters = []
            self.error = "Failed to load filters"
        }
    }

    func createFilter(
        criteria: GmailFilter.FilterCriteria,
        action: GmailFilter.FilterAction
    ) async throws -> GmailFilter {
        let filter = try await GmailFilterService.shared.createFilter(
            criteria: criteria,
            action: action,
            accountID: accountID
        )
        await loadFilters()
        return filter
    }

    func deleteFilter(id: String) async {
        try? await GmailFilterService.shared.deleteFilter(id: id, accountID: accountID)
        await loadFilters()
    }
}
