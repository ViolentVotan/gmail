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

private struct SnoozeFileContents: Codable {
    var version: Int = 1
    var items: [SnoozedItem] = []
}

@Observable
@MainActor
final class SnoozeStore {
    static let shared = SnoozeStore()
    private init() {}

    /// Per-account storage keyed by accountID. Eliminates cross-account bleed
    /// and makes load(accountID:) atomic (a single dictionary assignment rather
    /// than removeAll + append which is non-atomic under observation).
    private var itemsByAccount: [String: [SnoozedItem]] = [:]

    /// Flat view of all items across all accounts. Preserves the public API
    /// shape that callers (e.g. AppCoordinator) depend on.
    private(set) var items: [SnoozedItem] {
        get { itemsByAccount.values.flatMap { $0 } }
        set { assertionFailure("Mutate itemsByAccount instead") }
    }

    func load(accountID: String) {
        let url = fileURL(for: accountID)
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(SnoozeFileContents.self, from: data) else { return }
        // Atomic replacement: a single dictionary write rather than removeAll + append
        itemsByAccount[accountID] = contents.items.filter { $0.accountID == accountID }
    }

    func add(_ item: SnoozedItem) {
        itemsByAccount[item.accountID, default: []].append(item)
        save(accountID: item.accountID)
    }

    func remove(messageId: String, accountID: String) {
        itemsByAccount[accountID]?.removeAll { $0.messageId == messageId }
        save(accountID: accountID)
    }

    func expiredItems() -> [SnoozedItem] {
        let now = Date()
        return itemsByAccount.values.flatMap { $0 }.filter { $0.snoozeUntil <= now }
    }

    func itemsForAccount(_ accountID: String) -> [SnoozedItem] {
        itemsByAccount[accountID] ?? []
    }

    private func save(accountID: String) {
        let url = fileURL(for: accountID)
        let contents = SnoozeFileContents(version: 1, items: itemsByAccount[accountID] ?? [])
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(contents).write(to: url, options: .atomic)
    }

    private func fileURL(for accountID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vikingz.serif.app/mail-cache/\(accountID)/snoozed.json")
    }
}
