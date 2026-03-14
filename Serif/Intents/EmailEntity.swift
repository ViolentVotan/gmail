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
        var entities: [EmailEntity] = []
        let accounts = await MainActor.run { AccountStore.shared.accounts }
        for account in accounts {
            guard let db = try? MailDatabase.shared(for: account.id) else { continue }
            for id in identifiers {
                if let record = try? await db.dbPool.read({ db in
                    try MessageRecord.fetchOne(db, key: id)
                }) {
                    entities.append(EmailEntity(
                        id: record.gmailId,
                        subject: record.subject ?? "",
                        senderName: record.senderName ?? record.senderEmail ?? "",
                        date: Date(timeIntervalSince1970: record.internalDate)
                    ))
                }
            }
        }
        return entities
    }

    func suggestedEntities() async throws -> [EmailEntity] {
        return await Array(allCachedMessages().prefix(20))
    }

    // MARK: - Private

    private func allCachedMessages() async -> [EmailEntity] {
        let accounts = await MainActor.run { AccountStore.shared.accounts }
        var entities: [EmailEntity] = []
        for account in accounts {
            guard let db = try? MailDatabase.shared(for: account.id) else { continue }
            let records = try? await db.dbPool.read { database in
                try MailDatabaseQueries.messagesForLabel("INBOX", limit: 200, in: database)
            }
            guard let records else { continue }
            for record in records {
                entities.append(EmailEntity(
                    id: record.gmailId,
                    subject: record.subject ?? "",
                    senderName: record.senderName ?? record.senderEmail ?? "",
                    date: Date(timeIntervalSince1970: record.internalDate)
                ))
            }
        }
        return entities
    }
}
