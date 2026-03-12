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

    private(set) var items: [SnoozedItem] = []

    func load(accountID: String) {
        let url = fileURL(for: accountID)
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(SnoozeFileContents.self, from: data) else { return }
        // Remove existing items for this account, then add loaded ones
        items.removeAll { $0.accountID == accountID }
        items.append(contentsOf: contents.items.filter { $0.accountID == accountID })
    }

    func add(_ item: SnoozedItem) {
        items.append(item)
        save(accountID: item.accountID)
    }

    func remove(messageId: String, accountID: String) {
        items.removeAll { $0.messageId == messageId && $0.accountID == accountID }
        save(accountID: accountID)
    }

    func expiredItems() -> [SnoozedItem] {
        let now = Date()
        return items.filter { $0.snoozeUntil <= now }
    }

    func itemsForAccount(_ accountID: String) -> [SnoozedItem] {
        items.filter { $0.accountID == accountID }
    }

    private func save(accountID: String) {
        let url = fileURL(for: accountID)
        let contents = SnoozeFileContents(version: 1, items: items.filter { $0.accountID == accountID })
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(contents).write(to: url, options: .atomic)
    }

    private func fileURL(for accountID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.genyus.serif.app/mail-cache/\(accountID)/snoozed.json")
    }
}
