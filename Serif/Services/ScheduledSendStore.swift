import Foundation

struct ScheduledSendItem: Codable, Identifiable, Sendable {
    let id: UUID
    let draftId: String
    let accountID: String
    let scheduledTime: Date
    let subject: String
    let recipients: [String]

    init(
        id: UUID = UUID(),
        draftId: String,
        accountID: String,
        scheduledTime: Date,
        subject: String = "",
        recipients: [String] = []
    ) {
        self.id = id
        self.draftId = draftId
        self.accountID = accountID
        self.scheduledTime = scheduledTime
        self.subject = subject
        self.recipients = recipients
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
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.vikingz.serif.app/mail-cache/\(accountID)/scheduled.json")
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

    func load(accountID: String) {
        store.load(accountID: accountID)
        // Filter out items that don't match the account (legacy safety)
        store.replaceItems(
            (store.itemsByAccount[accountID] ?? []).filter { $0.accountID == accountID },
            accountID: accountID
        )
    }

    func add(_ item: ScheduledSendItem) {
        store.append(item, accountID: item.accountID)
        store.save(accountID: item.accountID)
    }

    func remove(draftId: String, accountID: String) {
        store.removeAll(accountID: accountID) { $0.draftId == draftId }
        store.save(accountID: accountID)
    }

    /// Removes all in-memory data and the on-disk JSON file for the given account.
    func deleteAccount(_ accountID: String) {
        store.deleteAccount(accountID)
    }

    func dueItems() -> [ScheduledSendItem] {
        let now = Date()
        return store.allItems.filter { $0.scheduledTime <= now }
    }
}
