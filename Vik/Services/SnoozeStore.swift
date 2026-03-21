import Foundation

struct SnoozedItem: Codable, Identifiable, Sendable {
    let id: UUID
    let messageId: String
    let threadId: String?
    let accountID: String
    let snoozeUntil: Date
    let originalLabelIds: [String]
    let subject: String
    let senderName: String

    init(
        id: UUID = UUID(),
        messageId: String,
        threadId: String? = nil,
        accountID: String,
        snoozeUntil: Date,
        originalLabelIds: [String] = [],
        subject: String = "",
        senderName: String = ""
    ) {
        self.id = id
        self.messageId = messageId
        self.threadId = threadId
        self.accountID = accountID
        self.snoozeUntil = snoozeUntil
        self.originalLabelIds = originalLabelIds
        self.subject = subject
        self.senderName = senderName
    }
}

/// Legacy on-disk format (version 1). Kept only for migration.
private struct LegacySnoozeFileContents: Codable, Sendable {
    var version: Int = 1
    var items: [SnoozedItem] = []
}

@Observable
@MainActor
final class SnoozeStore {
    static let shared = SnoozeStore()

    private let store = PerAccountFileStore<SnoozedItem>(
        fileURL: { accountID in
            AppPaths.appSupportDirectory
                .appendingPathComponent("mail-data/\(accountID)/snoozed.json")
        },
        legacyDecoder: { data in
            guard let contents = try? JSONDecoder().decode(LegacySnoozeFileContents.self, from: data) else {
                return nil
            }
            return contents.items
        }
    )

    private init() {}

    /// Flat view of all items across all accounts. Preserves the public API
    /// shape that callers (e.g. AppCoordinator) depend on.
    var items: [SnoozedItem] {
        store.allItems
    }

    var count: Int { store.totalCount }

    func load(accountID: String) async {
        await store.loadFiltered(by: accountID, keyPath: \.accountID)
    }

    func add(_ item: SnoozedItem) {
        store.append(item, accountID: item.accountID)
    }

    func remove(messageId: String, accountID: String) {
        store.removeAll(accountID: accountID) { $0.messageId == messageId }
    }

    /// Removes all in-memory data and the on-disk JSON file for the given account.
    func deleteAccount(_ accountID: String) {
        store.deleteAccount(accountID)
    }

    func expiredItems() -> [SnoozedItem] {
        let now = Date()
        return store.filteredItems { $0.snoozeUntil <= now }
    }
}
