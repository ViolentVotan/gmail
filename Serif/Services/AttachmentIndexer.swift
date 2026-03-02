import Foundation

actor AttachmentIndexer {
    private let database: AttachmentDatabase
    private let messageService: GmailMessageService
    private let accountID: String
    private var isProcessing = false
    private let maxConcurrent = 3
    private let maxRetries = 3

    /// Called on @MainActor after each indexing batch so the UI can refresh stats.
    var onProgressUpdate: (@MainActor () -> Void)?

    init(database: AttachmentDatabase, messageService: GmailMessageService, accountID: String) {
        self.database = database
        self.messageService = messageService
        self.accountID = accountID
    }

    /// Register new attachments from fetched emails. Inserts metadata, triggers indexing.
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
                extractedText: nil
            )
            database.insertAttachment(indexed)
        }
        await processQueue()
    }

    /// Resume pending + retry failed items. Call on app launch.
    func resumeQueue() async {
        database.resetFailedForRetry(maxRetries: maxRetries)
        await processQueue()
    }

    /// Process pending attachments
    func processQueue() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        var pending = database.pendingAttachments(limit: maxConcurrent)
        while !pending.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for att in pending {
                    group.addTask { [self] in
                        await self.indexAttachment(att)
                    }
                }
            }
            // Notify UI after each batch
            if let onProgress = onProgressUpdate {
                await onProgress()
            }
            pending = database.pendingAttachments(limit: maxConcurrent)
        }
    }

    private func indexAttachment(_ att: IndexedAttachment) async {
        do {
            let data = try await messageService.getAttachment(
                messageID: att.messageId,
                attachmentID: att.attachmentId,
                accountID: accountID
            )

            let result = await ContentExtractor.extract(
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
}
