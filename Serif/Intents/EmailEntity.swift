import AppIntents
private import GRDB

// MARK: - Mail Account Entity

struct MailAccountEntity: AppEntity {
    static let defaultQuery = MailAccountEntityQuery()
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mail Account"

    var id: String // Account ID
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }

    init(id: String) {
        self.id = id
    }

    struct MailAccountEntityQuery: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [MailAccountEntity] {
            let accounts = await MainActor.run { AccountStore.shared.accounts }
            return accounts
                .filter { identifiers.contains($0.id) }
                .map { MailAccountEntity(id: $0.id) }
        }

        func suggestedEntities() async throws -> [MailAccountEntity] {
            let accounts = await MainActor.run { AccountStore.shared.accounts }
            return accounts.map { MailAccountEntity(id: $0.id) }
        }
    }
}

// MARK: - Mailbox Entity

struct MailboxEntity: AppEntity {
    static let defaultQuery = MailboxEntityQuery()
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mailbox"

    var id: String // Gmail label ID (e.g. "INBOX", "TRASH")
    @Property(title: "Name")
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    struct MailboxEntityQuery: EntityStringQuery {
        func entities(for identifiers: [String]) async throws -> [MailboxEntity] {
            identifiers.map { id in
                MailboxEntity(id: id, name: Self.displayName(for: id))
            }
        }

        func entities(matching string: String) async throws -> [MailboxEntity] {
            let all = Self.systemMailboxes
            let lower = string.lowercased()
            return all.filter { $0.name.lowercased().contains(lower) }
        }

        func suggestedEntities() async throws -> [MailboxEntity] {
            Self.systemMailboxes
        }

        private static var systemMailboxes: [MailboxEntity] {
            [
                MailboxEntity(id: GmailSystemLabel.inbox, name: "Inbox"),
                MailboxEntity(id: GmailSystemLabel.starred, name: "Starred"),
                MailboxEntity(id: GmailSystemLabel.sent, name: "Sent"),
                MailboxEntity(id: GmailSystemLabel.draft, name: "Drafts"),
                MailboxEntity(id: GmailSystemLabel.spam, name: "Spam"),
                MailboxEntity(id: GmailSystemLabel.trash, name: "Trash"),
                MailboxEntity(id: GmailSystemLabel.important, name: "Important"),
            ]
        }

        private static func displayName(for labelID: String) -> String {
            switch labelID {
            case GmailSystemLabel.inbox: "Inbox"
            case GmailSystemLabel.starred: "Starred"
            case GmailSystemLabel.sent: "Sent"
            case GmailSystemLabel.draft: "Drafts"
            case GmailSystemLabel.spam: "Spam"
            case GmailSystemLabel.trash: "Trash"
            case GmailSystemLabel.important: "Important"
            default: labelID
            }
        }
    }
}

// MARK: - Mail Message Entity

@AppEntity(schema: .mail.message)
struct MailMessageEntity: IndexedEntity {
    static let defaultQuery = MailMessageEntityQuery()
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Email"

    var id: String // Gmail message ID

    @Property var subject: String?
    @Property var sender: IntentPerson
    @Property var to: [IntentPerson]
    @Property var cc: [IntentPerson]
    @Property var body: AttributedString?
    @Property var dateSent: Date
    @Property var dateReceived: Date
    @Property var isRead: Bool
    @Property var isFlagged: Bool
    @Property var account: MailAccountEntity
    @Property var mailbox: MailboxEntity

    var displayRepresentation: DisplayRepresentation {
        let senderLabel: String
        switch sender.name {
        case .displayName(let name): senderLabel = name
        default:
            if let handle = sender.handle, case .emailAddress(let email) = handle.value {
                senderLabel = email
            } else {
                senderLabel = "Unknown"
            }
        }
        return DisplayRepresentation(
            title: "\(subject ?? "(No Subject)")",
            subtitle: "\(senderLabel)"
        )
    }

    init() {
        self.id = ""
        self.subject = nil
        self.sender = Self.makePerson(email: "", name: "")
        self.to = []
        self.cc = []
        self.body = nil
        self.dateSent = Date()
        self.dateReceived = Date()
        self.isRead = false
        self.isFlagged = false
        self.account = MailAccountEntity(id: "")
        self.mailbox = MailboxEntity(id: GmailSystemLabel.inbox, name: "Inbox")
    }

    init(record: MessageRecord, accountID: String) {
        self.id = record.gmailId

        self.subject = record.subject

        let senderEmail = record.senderEmail ?? ""
        let senderDisplayName = record.senderName ?? senderEmail
        self.sender = Self.makePerson(email: senderEmail, name: senderDisplayName)

        self.to = Self.parseRecipients(record.toRecipients)
        self.cc = Self.parseRecipients(record.ccRecipients)

        if let snippet = record.snippet {
            self.body = AttributedString(snippet)
        } else {
            self.body = nil
        }

        let messageDate = Date(timeIntervalSince1970: record.internalDate)
        self.dateSent = messageDate
        self.dateReceived = messageDate

        self.isRead = record.isRead
        self.isFlagged = record.isStarred

        self.account = MailAccountEntity(id: accountID)
        self.mailbox = MailboxEntity(id: GmailSystemLabel.inbox, name: "Inbox")
    }

    init(from email: Email) {
        self.id = email.gmailMessageID ?? email.id.uuidString

        self.subject = email.subject

        self.sender = Self.makePerson(email: email.sender.email, name: email.sender.name)

        self.to = email.recipients.map {
            Self.makePerson(email: $0.email, name: $0.name)
        }
        self.cc = email.cc.map {
            Self.makePerson(email: $0.email, name: $0.name)
        }

        self.body = email.preview.isEmpty ? nil : AttributedString(email.preview)

        self.dateSent = email.date
        self.dateReceived = email.date
        self.isRead = email.isRead
        self.isFlagged = email.isStarred
        self.account = MailAccountEntity(id: "")
        self.mailbox = MailboxEntity(id: GmailSystemLabel.inbox, name: "Inbox")
    }

    // MARK: - Private

    private static func makePerson(email: String, name: String) -> IntentPerson {
        let handle = IntentPerson.Handle(emailAddress: email)
        return IntentPerson(
            identifier: .applicationDefined(email),
            name: .displayName(name),
            handle: handle
        )
    }

    private static func parseRecipients(_ jsonString: String?) -> [IntentPerson] {
        guard let jsonString, !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data) else {
            return []
        }
        return pairs.map { pair in
            let email = pair.first ?? ""
            let name = pair.count > 1 ? pair[1] : email
            return makePerson(email: email, name: name)
        }
    }
}

// MARK: - Entity Query

struct MailMessageEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [MailMessageEntity] {
        let messages = await allCachedMessages()
        let lower = string.lowercased()
        return messages.filter { entity in
            if entity.subject?.lowercased().contains(lower) == true { return true }
            if case .displayName(let name) = entity.sender.name,
               name.lowercased().contains(lower) { return true }
            return false
        }
    }

    func entities(for identifiers: [String]) async throws -> [MailMessageEntity] {
        guard !identifiers.isEmpty else { return [] }
        var entities: [MailMessageEntity] = []
        let accounts = await MainActor.run { AccountStore.shared.accounts }
        for account in accounts {
            guard let db = try? MailDatabase.shared(for: account.id) else { continue }
            let records = try? await db.dbPool.read { database in
                try MessageRecord.filter(identifiers.contains(Column("gmail_id"))).fetchAll(database)
            }
            guard let records else { continue }
            for record in records {
                entities.append(MailMessageEntity(record: record, accountID: account.id))
            }
        }
        return entities
    }

    func suggestedEntities() async throws -> [MailMessageEntity] {
        await Array(allCachedMessages().prefix(20))
    }

    // MARK: - Private

    private func allCachedMessages() async -> [MailMessageEntity] {
        let accounts = await MainActor.run { AccountStore.shared.accounts }
        var entities: [MailMessageEntity] = []
        for account in accounts {
            guard let db = try? MailDatabase.shared(for: account.id) else { continue }
            let records = try? await db.dbPool.read { database in
                try MailDatabaseQueries.messagesForLabel(GmailSystemLabel.inbox, limit: 200, in: database)
            }
            guard let records else { continue }
            for record in records {
                entities.append(MailMessageEntity(record: record, accountID: account.id))
            }
        }
        return entities
    }
}

// MARK: - Legacy Alias

/// Backward-compatible type alias for SpotlightIndexer and other callers.
typealias EmailEntity = MailMessageEntity
