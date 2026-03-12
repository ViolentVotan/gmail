import AppIntents
import Foundation

struct EmailEntity: IndexedEntity {
    static let defaultQuery = EmailEntityQuery()
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Email"

    @Property(title: "Subject")
    var subject: String

    @Property(title: "Sender")
    var senderName: String

    @Property(title: "Date")
    var date: Date

    var id: String // Gmail message ID

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(subject)", subtitle: "\(senderName)")
    }

    init() {
        self.id = ""
        self.subject = ""
        self.senderName = ""
        self.date = Date()
    }

    init(id: String, subject: String, senderName: String, date: Date) {
        self.id = id
        self.subject = subject
        self.senderName = senderName
        self.date = date
    }
}

// MARK: - Entity Query

struct EmailEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [EmailEntity] {
        let messages = await allCachedMessages()
        let lower = string.lowercased()
        return messages.filter {
            $0.subject.lowercased().contains(lower) || $0.senderName.lowercased().contains(lower)
        }
    }

    func entities(for identifiers: [String]) async throws -> [EmailEntity] {
        let messages = await allCachedMessages()
        let idSet = Set(identifiers)
        return messages.filter { idSet.contains($0.id) }
    }

    func suggestedEntities() async throws -> [EmailEntity] {
        return await Array(allCachedMessages().prefix(20))
    }

    // MARK: - Private

    @MainActor
    private func allCachedMessages() async -> [EmailEntity] {
        let accounts = AccountStore.shared.accounts
        var entities: [EmailEntity] = []
        for account in accounts {
            let inboxKey = MailCacheStore.folderKey(labelIDs: ["INBOX"], query: nil)
            let cache = await MailCacheStore.shared.loadFolderCache(accountID: account.id, folderKey: inboxKey)
            for message in cache.messages {
                let dateMs = Double(message.internalDate ?? "0") ?? 0
                let date = Date(timeIntervalSince1970: dateMs / 1000)
                entities.append(EmailEntity(
                    id: message.id,
                    subject: message.subject,
                    senderName: message.from,
                    date: date
                ))
            }
        }
        return entities
    }
}
