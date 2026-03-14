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

private struct ScheduledFileContents: Codable {
    var version: Int = 1
    var items: [ScheduledSendItem] = []
}

@Observable
@MainActor
final class ScheduledSendStore {
    static let shared = ScheduledSendStore()
    private init() {}

    /// Per-account storage keyed by accountID. Eliminates cross-account bleed
    /// and makes load(accountID:) atomic (a single dictionary assignment rather
    /// than removeAll + append which is non-atomic under observation).
    private var itemsByAccount: [String: [ScheduledSendItem]] = [:]

    /// Flat view of all items across all accounts. Preserves the public API
    /// shape that callers (e.g. AppCoordinator) depend on.
    private(set) var items: [ScheduledSendItem] {
        get { itemsByAccount.values.flatMap { $0 } }
        set { assertionFailure("Mutate itemsByAccount instead") }
    }

    func load(accountID: String) {
        let url = fileURL(for: accountID)
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(ScheduledFileContents.self, from: data) else { return }
        // Atomic replacement: a single dictionary write rather than removeAll + append
        itemsByAccount[accountID] = contents.items.filter { $0.accountID == accountID }
    }

    func add(_ item: ScheduledSendItem) {
        itemsByAccount[item.accountID, default: []].append(item)
        save(accountID: item.accountID)
    }

    func remove(draftId: String, accountID: String) {
        itemsByAccount[accountID]?.removeAll { $0.draftId == draftId }
        save(accountID: accountID)
    }

    func dueItems() -> [ScheduledSendItem] {
        let now = Date()
        return itemsByAccount.values.flatMap { $0 }.filter { $0.scheduledTime <= now }
    }

    private func save(accountID: String) {
        let url = fileURL(for: accountID)
        let contents = ScheduledFileContents(version: 1, items: itemsByAccount[accountID] ?? [])
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(contents).write(to: url, options: .atomic)
    }

    private func fileURL(for accountID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vikingz.serif.app/mail-cache/\(accountID)/scheduled.json")
    }
}
