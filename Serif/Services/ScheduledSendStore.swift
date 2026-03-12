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

    private(set) var items: [ScheduledSendItem] = []

    func load(accountID: String) {
        let url = fileURL(for: accountID)
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(ScheduledFileContents.self, from: data) else {
            items = []
            return
        }
        items = contents.items.filter { $0.accountID == accountID }
    }

    func add(_ item: ScheduledSendItem) {
        items.append(item)
        save(accountID: item.accountID)
    }

    func remove(draftId: String, accountID: String) {
        items.removeAll { $0.draftId == draftId && $0.accountID == accountID }
        save(accountID: accountID)
    }

    func dueItems() -> [ScheduledSendItem] {
        let now = Date()
        return items.filter { $0.scheduledTime <= now }
    }

    private func save(accountID: String) {
        let url = fileURL(for: accountID)
        let contents = ScheduledFileContents(version: 1, items: items.filter { $0.accountID == accountID })
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(contents).write(to: url, options: .atomic)
    }

    private func fileURL(for accountID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.genyus.serif.app/mail-cache/\(accountID)/scheduled.json")
    }
}
