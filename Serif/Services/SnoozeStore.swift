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
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.vikingz.serif.app/mail-cache/\(accountID)/snoozed.json")
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

    func load(accountID: String) {
        store.load(accountID: accountID)
        // Filter out items that don't match the account (legacy safety)
        store.replaceItems(
            (store.itemsByAccount[accountID] ?? []).filter { $0.accountID == accountID },
            accountID: accountID
        )
    }

    func add(_ item: SnoozedItem) {
        store.append(item, accountID: item.accountID)
        store.save(accountID: item.accountID)
    }

    func remove(messageId: String, accountID: String) {
        store.removeAll(accountID: accountID) { $0.messageId == messageId }
        store.save(accountID: accountID)
    }

    /// Removes all in-memory data and the on-disk JSON file for the given account.
    func deleteAccount(_ accountID: String) {
        store.deleteAccount(accountID)
    }

    func expiredItems() -> [SnoozedItem] {
        let now = Date()
        return store.allItems.filter { $0.snoozeUntil <= now }
    }
}
