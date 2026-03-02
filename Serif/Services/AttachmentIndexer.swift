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
                emailBody: nil,
                accountID: accountID
            )
            database.insertAttachment(indexed)
        }
        await processQueue()
    }

    // MARK: - Resume (app launch)

    /// Resume pending + retry failed items.
    func resumePending() async {
        database.resetFailedForRetry(maxRetries: maxRetries, accountID: accountID)
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

        var pending = db.pendingAttachments(limit: maxConcurrent, accountID: acctID)
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
            pending = db.pendingAttachments(limit: maxConcurrent, accountID: acctID)
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

    // MARK: - Active Scan (queries API for messages with attachments)

    private var isScanning = false

    /// Max messages to scan exploratively. Beyond this limit, attachments are
    /// discovered only when the user opens an email (full-format fetch).
    private let scanLimit = 3000

    /// Scans the account for messages with attachments using `has:attachment` query.
    /// Paginates up to `scanLimit` messages, fetches each batch in full format, and registers them.
    /// Safe to call multiple times — skips if already scanning.
    func scanForAttachments() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let service = messageService
        let acctID = accountID
        let db = database
        var pageToken: String? = nil
        var totalDiscovered = 0
        var totalScanned = 0

        do {
            repeat {
                let list = try await service.listMessages(
                    accountID: acctID,
                    labelIDs: [],
                    query: "has:attachment",
                    pageToken: pageToken
                )
                let refs = list.messages ?? []
                pageToken = list.nextPageToken

                guard !refs.isEmpty else { break }
                totalScanned += refs.count

                // Filter out already-processed messages
                let toScan = refs.filter { ref in
                    !processedMessageIDs.contains(ref.id) && !db.hasMessageAttachments(messageId: ref.id)
                }

                // Mark all as seen
                for ref in refs { processedMessageIDs.insert(ref.id) }

                if !toScan.isEmpty {
                    // Fetch in full format to get parts + body
                    let messages = try await service.getMessages(
                        ids: toScan.map(\.id),
                        accountID: acctID,
                        format: "full"
                    )

                    totalDiscovered += messages.count
                    print("[AttachmentIndexer] Scanned page: \(messages.count) messages with attachments (total: \(totalDiscovered)/\(totalScanned) scanned)")

                    // Register + process immediately so UI updates incrementally
                    await registerFromFullMessages(messages: messages)
                }
            } while pageToken != nil && totalScanned < scanLimit

            if totalDiscovered > 0 {
                print("[AttachmentIndexer] Scan complete: \(totalDiscovered) messages with attachments out of \(totalScanned) scanned (limit: \(scanLimit))")
            }
        } catch {
            print("[AttachmentIndexer] Scan failed: \(error)")
        }
    }

    // MARK: - Register from metadata-format messages (mailbox list)

    /// Register attachments from metadata-format messages (no body available).
    /// Note: metadata format lacks parts info, so this only works for messages
    /// already fetched in full format and cached.
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
                    extractedText: nil, emailBody: nil,
                    accountID: accountID
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
                    extractedText: nil, emailBody: body,
                    accountID: accountID
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
