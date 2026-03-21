import Foundation

/// Dedicated @Observable store for the current account's contacts.
/// Owned by SyncCoordinator; consumed directly by views/VMs that need contacts.
/// Isolation from SyncCoordinator prevents unrelated DB-change observations from
/// causing contact-consumer views to re-render.
@Observable
@MainActor
final class ContactsStore {

    private(set) var contacts: [StoredContact] = []

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Load contacts for the given account from the database.
    /// Caps at 5 000 entries to bound memory and SwiftUI diff cost.
    func load(accountID: String, database: MailDatabase) {
        guard !accountID.isEmpty else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result = (try? await database.dbPool.read { db in
                try MailDatabaseQueries.allContacts(limit: 5_000, in: db).map {
                    StoredContact(name: $0.name ?? $0.email, email: $0.email, photoURL: $0.photoUrl)
                }
            }) ?? []
            guard !Task.isCancelled else { return }
            guard let self else { return }
            contacts = result
        }
    }

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    func clear() {
        cancelLoad()
        contacts = []
    }
}
