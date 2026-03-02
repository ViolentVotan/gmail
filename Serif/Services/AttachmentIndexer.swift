import Foundation

actor AttachmentIndexer {
    private let database: AttachmentDatabase
    private let messageService: GmailMessageService
    private let accountID: String
    private var isProcessing = false
    private let maxConcurrent = 3
    private let maxRetries = 3
    /// In-memory set of message IDs already processed — avoids redundant DB queries on repeated fetches.
    private var processedMessageIDs: Set<String> = []

    /// Called on @MainActor after each indexing batch so the UI can refresh stats.
    var onProgressUpdate: (@MainActor () -> Void)?

    init(database: AttachmentDatabase, messageService: GmailMessageService, accountID: String) {
        self.database = database
        self.messageService = messageService
        self.accountID = accountID
    }

    // MARK: - Passive Registration (from already-fetched emails)

    /// Register attachments from emails that were fetched in full format (e.g., thread detail view).
    func register(attachments: [(attachment: Attachment, email: Email)]) async {
        for (att, email) in attachments {
            guard let gmailAttachmentId = att.gmailAttachmentId,
                  let gmailMessageId = att.gmailMessageId else { continue }

            let id = "\(gmailMessageId)_\(gmailAttachmentId)"
            guard !database.exists(id: id) else { continue }

            let indexed = IndexedAttachment(
                id: id,
                messageId: gmailMessageId,
                attachmentId: gmailAttachmentId,
                filename: att.name,
                mimeType: att.mimeType,
                fileType: att.fileType.rawValue,
                size: 0,
                senderEmail: email.sender.email,
                senderName: email.sender.name,
                emailSubject: email.subject,
                emailDate: email.date,
                direction: email.folder == .sent ? .sent : .received,
                indexedAt: nil,
                indexingStatus: .pending,
                extractedText: nil,
                emailBody: nil
            )
            database.insertAttachment(indexed)
        }
        await processQueue()
    }

    // MARK: - Resume (app launch)

    /// Resume pending + retry failed items.
    func resumePending() async {
        database.resetFailedForRetry(maxRetries: maxRetries)
        await processQueue()
    }

    // MARK: - Process Queue

    func processQueue() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        // Capture actor-isolated properties once so task group children run off-actor
        let db = database
        let service = messageService
        let acctID = accountID

        var pending = db.pendingAttachments(limit: maxConcurrent)
        while !pending.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for att in pending {
                    group.addTask {
                        await Self.indexAttachment(att, database: db, messageService: service, accountID: acctID)
                    }
                }
            }
            if let onProgress = onProgressUpdate {
                await onProgress()
            }
            pending = db.pendingAttachments(limit: maxConcurrent)
        }
    }

    // MARK: - Index single attachment (static, runs off-actor)

    private static func indexAttachment(
        _ att: IndexedAttachment,
        database: AttachmentDatabase,
        messageService: GmailMessageService,
        accountID: String
    ) async {
        do {
            let data = try await messageService.getAttachment(
                messageID: att.messageId,
                attachmentID: att.attachmentId,
                accountID: accountID
            )

            let result = ContentExtractor.extract(
                from: data,
                mimeType: att.mimeType,
                filename: att.filename
            )

            switch result {
            case .text(let text):
                let embedding = ContentExtractor.generateEmbedding(for: text)
                database.updateIndexedContent(id: att.id, text: text, embedding: embedding, status: .indexed)
                print("[AttachmentIndexer] Indexed: \(att.filename)")
            case .unsupported:
                database.updateIndexedContent(id: att.id, text: nil, embedding: nil, status: .unsupported)
                print("[AttachmentIndexer] Unsupported: \(att.filename)")
            }
        } catch {
            database.incrementRetry(id: att.id)
            print("[AttachmentIndexer] Failed: \(att.filename) — \(error)")
        }
    }

    // MARK: - Register from metadata-format messages (mailbox list)

    /// Register attachments from metadata-format messages (no body available).
    func registerFromMetadata(messages: [GmailMessage]) async {
        for message in messages {
            let parts = message.attachmentParts
            guard !parts.isEmpty else { continue }
            guard !processedMessageIDs.contains(message.id) else { continue }
            guard !database.hasMessageAttachments(messageId: message.id) else {
                processedMessageIDs.insert(message.id)
                continue
            }

            let labels = message.labelIds ?? []
            let direction: IndexedAttachment.Direction = labels.contains("SENT") ? .sent : .received
            let fromRaw = message.from
            let senderEmail = fromRaw.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
            let senderName = fromRaw.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            for part in parts {
                guard let attachmentId = part.body?.attachmentId else { continue }
                let id = "\(message.id)_\(attachmentId)"
                guard !database.exists(id: id) else { continue }
                let name = part.filename ?? "attachment"
                let ext = String(name.split(separator: ".").last ?? "")
                let indexed = IndexedAttachment(
                    id: id, messageId: message.id, attachmentId: attachmentId,
                    filename: name, mimeType: part.mimeType,
                    fileType: Attachment.FileType.from(fileExtension: ext).rawValue,
                    size: part.body?.size ?? 0,
                    senderEmail: senderEmail, senderName: senderName,
                    emailSubject: message.subject, emailDate: message.date,
                    direction: direction, indexedAt: nil, indexingStatus: .pending,
                    extractedText: nil, emailBody: nil
                )
                database.insertAttachment(indexed)
            }
            processedMessageIDs.insert(message.id)
        }
        if let onProgress = onProgressUpdate { await onProgress() }
    }

    // MARK: - Register from full-format messages (thread detail)

    /// Register attachments from full-format messages (has body). Also enriches existing records.
    func registerFromFullMessages(messages: [GmailMessage]) async {
        var newCount = 0
        for message in messages {
            let parts = message.attachmentParts
            guard !parts.isEmpty else { continue }
            let alreadySeen = processedMessageIDs.contains(message.id)

            let labels = message.labelIds ?? []
            let direction: IndexedAttachment.Direction = labels.contains("SENT") ? .sent : .received
            let fromRaw = message.from
            let senderEmail = fromRaw.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
            let senderName = fromRaw.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let rawBody = message.plainBody ?? message.snippet
            let body = rawBody.map { String($0.prefix(5000)) }

            for part in parts {
                guard let attachmentId = part.body?.attachmentId else { continue }
                let id = "\(message.id)_\(attachmentId)"
                if database.exists(id: id) {
                    // Only enrich body if this message wasn't already fully processed
                    if !alreadySeen, let body = body { database.updateEmailBody(id: id, body: body) }
                    continue
                }
                let name = part.filename ?? "attachment"
                let ext = String(name.split(separator: ".").last ?? "")
                let indexed = IndexedAttachment(
                    id: id, messageId: message.id, attachmentId: attachmentId,
                    filename: name, mimeType: part.mimeType,
                    fileType: Attachment.FileType.from(fileExtension: ext).rawValue,
                    size: part.body?.size ?? 0,
                    senderEmail: senderEmail, senderName: senderName,
                    emailSubject: message.subject, emailDate: message.date,
                    direction: direction, indexedAt: nil, indexingStatus: .pending,
                    extractedText: nil, emailBody: body
                )
                database.insertAttachment(indexed)
                newCount += 1
            }
            processedMessageIDs.insert(message.id)
        }
        if let onProgress = onProgressUpdate { await onProgress() }
        if newCount > 0 { await processQueue() }
    }
}
