import Foundation

struct ScheduledSendItem: Codable, Identifiable, Sendable {
    let id: UUID
    let draftId: String
    let accountID: String
    let scheduledTime: Date
    let subject: String
    let recipients: [String]
    var failedPermanently: Bool

    init(
        id: UUID = UUID(),
        draftId: String,
        accountID: String,
        scheduledTime: Date,
        subject: String = "",
        recipients: [String] = [],
        failedPermanently: Bool = false
    ) {
        self.id = id
        self.draftId = draftId
        self.accountID = accountID
        self.scheduledTime = scheduledTime
        self.subject = subject
        self.recipients = recipients
        self.failedPermanently = failedPermanently
    }
}

/// Legacy on-disk format (version 1). Kept only for migration.
private struct LegacyScheduledFileContents: Codable, Sendable {
    var version: Int = 1
    var items: [ScheduledSendItem] = []
}

@Observable
@MainActor
final class ScheduledSendStore {
    static let shared = ScheduledSendStore()

    private let store = PerAccountFileStore<ScheduledSendItem>(
        fileURL: { accountID in
            AppPaths.appSupportDirectory
                .appendingPathComponent("mail-data/\(accountID)/scheduled.json")
        },
        legacyDecoder: { data in
            guard let contents = try? JSONDecoder().decode(LegacyScheduledFileContents.self, from: data) else {
                return nil
            }
            return contents.items
        }
    )

    private init() {}

    /// Flat view of all items across all accounts. Preserves the public API
    /// shape that callers (e.g. AppCoordinator) depend on.
    var items: [ScheduledSendItem] {
        store.allItems
    }

    var count: Int { store.totalCount }

    func load(accountID: String) async {
        await store.loadFiltered(by: accountID, keyPath: \.accountID)
    }

    func add(_ item: ScheduledSendItem) async {
        await store.appendAndWait(item, accountID: item.accountID)
    }

    func remove(draftId: String, accountID: String) async {
        await store.removeAllAndWait(accountID: accountID) { $0.draftId == draftId }
    }

    func markFailed(draftId: String, accountID: String) async {
        var items = store.itemsByAccount[accountID] ?? []
        guard let idx = items.firstIndex(where: { $0.draftId == draftId }) else { return }
        items[idx].failedPermanently = true
        store.replaceItems(items, accountID: accountID)
        await store.saveAndWait(accountID: accountID)
    }

    /// Removes all in-memory data and the on-disk JSON file for the given account.
    func deleteAccount(_ accountID: String) {
        store.deleteAccount(accountID)
    }

    func dueItems() -> [ScheduledSendItem] {
        let now = Date()
        return store.filteredItems { $0.scheduledTime <= now && !$0.failedPermanently }
    }
}
