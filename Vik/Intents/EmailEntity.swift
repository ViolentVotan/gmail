import AppIntents
internal import GRDB

// MARK: - Mail Account Entity

@AppEntity(schema: .mail.account)
struct MailAccountEntity {
    static let defaultQuery = MailAccountEntityQuery()

    var id: String // Account ID
    @Property var name: String
    @Property var emailAddress: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name.isEmpty ? id : name)")
    }

    init(id: String, name: String = "", emailAddress: String = "") {
        self.id = id
        self.name = name
        self.emailAddress = emailAddress
    }

    struct MailAccountEntityQuery: EntityStringQuery {
        func entities(for identifiers: [String]) async throws -> [MailAccountEntity] {
            let accounts = await MainActor.run { AccountStore.shared.accounts }
            return accounts
                .filter { identifiers.contains($0.id) }
                .map { MailAccountEntity(id: $0.id, name: $0.displayName, emailAddress: $0.email) }
        }

        func entities(matching string: String) async throws -> [MailAccountEntity] {
            let accounts = await MainActor.run { AccountStore.shared.accounts }
            let lower = string.lowercased()
            return accounts
                .filter {
                    $0.email.lowercased().contains(lower) ||
                    $0.displayName.lowercased().contains(lower)
                }
                .map { MailAccountEntity(id: $0.id, name: $0.displayName, emailAddress: $0.email) }
        }

        func suggestedEntities() async throws -> [MailAccountEntity] {
            let accounts = await MainActor.run { AccountStore.shared.accounts }
            return accounts.map { MailAccountEntity(id: $0.id, name: $0.displayName, emailAddress: $0.email) }
        }
    }
}

// MARK: - Mailbox Entity

@AppEntity(schema: .mail.mailbox)
struct MailboxEntity {
    static let defaultQuery = MailboxEntityQuery()

    var id: String // Gmail label ID (e.g. "INBOX", "TRASH")
    @Property var name: String
    @Property var account: MailAccountEntity

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String, account: MailAccountEntity = MailAccountEntity(id: "")) {
        self.id = id
        self.name = name
        self.account = account
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

// MARK: - Mail Draft Entity

@AppEntity(schema: .mail.draft)
struct MailDraftEntity {
    static let defaultQuery = MailDraftEntityQuery()

    var id: String
    @Property var to: [IntentPerson]
    @Property var cc: [IntentPerson]
    @Property var bcc: [IntentPerson]
    @Property var subject: String?
    @Property var body: AttributedString?
    @Property var attachments: [IntentFile]
    @Property var account: MailAccountEntity

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(subject ?? "(No Subject)")")
    }

    init() {
        self.id = ""
        self.to = []
        self.cc = []
        self.bcc = []
        self.subject = nil
        self.body = nil
        self.attachments = []
        self.account = MailAccountEntity(id: "")
    }

    init(
        id: String,
        to: [IntentPerson] = [],
        cc: [IntentPerson] = [],
        bcc: [IntentPerson] = [],
        subject: String? = nil,
        body: AttributedString? = nil,
        account: MailAccountEntity = MailAccountEntity(id: "")
    ) {
        self.id = id
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.attachments = []
        self.account = account
    }

    struct MailDraftEntityQuery: EntityStringQuery {
        func entities(for identifiers: [String]) async throws -> [MailDraftEntity] {
            guard !identifiers.isEmpty else { return [] }
            var entities: [MailDraftEntity] = []
            let accounts = await MainActor.run { AccountStore.shared.accounts }
            for account in accounts {
                guard let db = try? await MailDatabase.shared(for: account.id) else { continue }
                // Entity IDs may be either a gmail_draft_id (preferred) or gmail_id (fallback
                // for pre-migration records). Search both columns to handle either case.
                let records = try? await db.dbPool.read { database in
                    try MessageRecord
                        .filter(
                            identifiers.contains(Column("gmail_draft_id"))
                            || identifiers.contains(Column("gmail_id"))
                        )
                        .fetchAll(database)
                }
                guard let records else { continue }
                for record in records {
                    entities.append(Self.makeDraftEntity(from: record, accountID: account.id))
                }
            }
            return entities
        }

        func entities(matching string: String) async throws -> [MailDraftEntity] {
            let drafts = await allDrafts()
            let lower = string.lowercased()
            return drafts.filter { entity in
                if entity.subject?.lowercased().contains(lower) == true { return true }
                for person in entity.to {
                    if case .displayName(let name) = person.name,
                       name.lowercased().contains(lower) { return true }
                }
                return false
            }
        }

        func suggestedEntities() async throws -> [MailDraftEntity] {
            await Array(allDrafts().prefix(10))
        }

        // MARK: - Private

        private func allDrafts() async -> [MailDraftEntity] {
            let accounts = await MainActor.run { AccountStore.shared.accounts }
            var entities: [MailDraftEntity] = []
            for account in accounts {
                guard let db = try? await MailDatabase.shared(for: account.id) else { continue }
                let records = try? await db.dbPool.read { database in
                    try MailDatabaseQueries.messagesForLabel(GmailSystemLabel.draft, limit: 50, in: database)
                }
                guard let records else { continue }
                for record in records {
                    entities.append(Self.makeDraftEntity(from: record, accountID: account.id))
                }
            }
            return entities
        }

        private static func makeDraftEntity(from record: MessageRecord, accountID: String) -> MailDraftEntity {
            let toPersons = parseRecipientString(record.toRecipients)
            let ccPersons = parseRecipientString(record.ccRecipients)
            // Use the Gmail draft ID for entity identity — the drafts/send API requires it.
            // Falls back to gmailId for pre-migration records that haven't been backfilled yet.
            return MailDraftEntity(
                id: record.gmailDraftId ?? record.gmailId,
                to: toPersons,
                cc: ccPersons,
                subject: record.subject,
                body: record.snippet.map { AttributedString($0) },
                account: MailAccountEntity(id: accountID)
            )
        }

        private static func parseRecipientString(_ jsonString: String?) -> [IntentPerson] {
            guard let jsonString, !jsonString.isEmpty,
                  let data = jsonString.data(using: .utf8),
                  let addresses = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return addresses.map { raw in
                let parsed = GmailDataTransformer.parseContactCore(raw)
                let handle = IntentPerson.Handle(emailAddress: parsed.email)
                return IntentPerson(
                    identifier: .applicationDefined(parsed.email),
                    name: .displayName(parsed.name),
                    handle: handle
                )
            }
        }
    }
}

// MARK: - Mail Message Entity

@AppEntity(schema: .mail.message)
struct MailMessageEntity: IndexedEntity {
    static let defaultQuery = MailMessageEntityQuery()

    var id: String // Gmail message ID

    @Property var subject: String?
    @Property var sender: IntentPerson
    @Property var to: [IntentPerson]
    @Property var cc: [IntentPerson]
    @Property var bcc: [IntentPerson]
    @Property var body: AttributedString?
    @Property var attachments: [IntentFile]
    @Property var dateSent: Date
    @Property var dateReceived: Date
    @Property var isRead: Bool
    @Property var isJunk: Bool
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
        self.bcc = []
        self.body = nil
        self.attachments = []
        self.dateSent = Date()
        self.dateReceived = Date()
        self.isRead = false
        self.isJunk = false
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
        self.bcc = []

        if let snippet = record.snippet {
            self.body = AttributedString(snippet)
        } else {
            self.body = nil
        }
        self.attachments = []

        let messageDate = Date(timeIntervalSince1970: record.internalDate)
        self.dateSent = messageDate
        self.dateReceived = messageDate

        self.isRead = record.isRead
        // MessageRecord is a bare row without joined label data; folder/junk cannot
        // be determined here. Callers that need accurate mailbox/isJunk should use
        // init(from:) with a fully-resolved Email value instead.
        self.isJunk = false
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
        self.bcc = []

        self.body = email.preview.isEmpty ? nil : AttributedString(email.preview)
        self.attachments = []

        self.dateSent = email.date
        self.dateReceived = email.date
        self.isRead = email.isRead
        self.isJunk = email.folder == .spam || email.gmailLabelIDs.contains(GmailSystemLabel.spam)
        self.isFlagged = email.isStarred
        self.account = MailAccountEntity(id: "")
        self.mailbox = MailboxEntity(
            id: email.folder.gmailLabelID ?? GmailSystemLabel.inbox,
            name: email.folder.rawValue
        )
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
              let addresses = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return addresses.map { raw in
            let parsed = GmailDataTransformer.parseContactCore(raw)
            return makePerson(email: parsed.email, name: parsed.name)
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
            guard let db = try? await MailDatabase.shared(for: account.id) else { continue }
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
            guard let db = try? await MailDatabase.shared(for: account.id) else { continue }
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

