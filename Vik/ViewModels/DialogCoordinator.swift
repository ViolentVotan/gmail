import Foundation

@Observable
@MainActor
final class DialogCoordinator {

    // MARK: - Confirmation State

    var showEmptyTrashConfirm = false
    var trashTotalCount = 0
    var showEmptySpamConfirm = false
    var spamTotalCount = 0

    // MARK: - Actions

    func emptyTrashRequested(count: Int) {
        trashTotalCount = count
        showEmptyTrashConfirm = true
    }

    func emptySpamRequested(count: Int) {
        spamTotalCount = count
        showEmptySpamConfirm = true
    }
}
