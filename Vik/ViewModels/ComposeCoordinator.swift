import Foundation

@Observable
@MainActor
final class ComposeCoordinator {

    // MARK: - State

    var composeMode: ComposeMode = .new
    var signatureForNew: String = ""
    var signatureForReply: String = ""

    // MARK: - Private State

    private var pendingDraftSelection: Email?

    // MARK: - Draft Selection

    /// Stores a draft to be selected after the folder change to .drafts completes.
    func setPendingDraftSelection(_ email: Email) {
        pendingDraftSelection = email
    }

    /// Returns and clears the pending draft selection, if any.
    func consumePendingDraftSelection() -> Email? {
        guard let pending = pendingDraftSelection else { return nil }
        pendingDraftSelection = nil
        return pending
    }

    // MARK: - Per-Account Signatures

    func loadSignatures(for id: String) {
        signatureForNew = UserDefaults.standard.string(forKey: UserDefaultsKey.signatureForNew(id)) ?? ""
        signatureForReply = UserDefaults.standard.string(forKey: UserDefaultsKey.signatureForReply(id)) ?? ""
    }

    func saveSignatures(for id: String) {
        UserDefaults.standard.set(signatureForNew, forKey: UserDefaultsKey.signatureForNew(id))
        UserDefaults.standard.set(signatureForReply, forKey: UserDefaultsKey.signatureForReply(id))
    }
}
