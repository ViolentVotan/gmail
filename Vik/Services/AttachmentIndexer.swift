import Foundation
private import os

// MARK: - BoundedIDCache

/// A fixed-capacity LRU cache of string IDs.
/// When full, the oldest-inserted entry is evicted. Thread-safe via actor isolation of the caller.
private struct BoundedIDCache {
    private let capacity: Int
    private var set: Set<String> = []
    /// Ordered from oldest to newest insertion.
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    func contains(_ id: String) -> Bool {
        set.contains(id)
    }

    mutating func insert(_ id: String) {
        guard !set.contains(id) else { return }
        if set.count >= capacity, let oldest = order.first {
            order.removeFirst()
            set.remove(oldest)
        }
        set.insert(id)
        order.append(id)
    }
}

actor AttachmentIndexer {
    nonisolated private static let logger = Logger(category: "AttachmentIndexer")
    private let database: AttachmentDatabase
    private let messageService: any MessageFetching
    private let accountID: String
    private var isProcessing = false
    private let maxConcurrent = 3
    private let maxRetries = 3
    private let cpuMonitor = CPUMonitor.shared

    /// LRU-bounded cache of recently-seen message IDs.
    /// Keeps memory usage fixed regardless of mailbox size.
    /// Cache misses fall back to a DB query.
    private var processedIDCache = BoundedIDCache(capacity: 10_000)

    /// Called on @MainActor after each indexing batch so the UI can refresh stats.
    var onProgressUpdate: (@MainActor () -> Void)?

    func setProgressUpdate(_ handler: (@MainActor () -> Void)?) {
        onProgressUpdate = handler
    }

    init(database: AttachmentDatabase, messageService: any MessageFetching, accountID: String) {
        self.database = database
        self.messageService = messageService
        self.accountID = accountID
    }

    // MARK: - Resume (app launch)

    /// Resume pending + retry failed items.
    func resumePending() async {
        await database.resetFailedForRetry(maxRetries: maxRetries, accountID: accountID)
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
        let monitor = cpuMonitor

        var pending = await db.pendingAttachments(limit: maxConcurrent, accountID: acctID)
        while !pending.isEmpty {
            // Stop processing if the owning task was cancelled (e.g., view disappeared)
            guard !Task.isCancelled else { break }
            // Hard gate: wait if process CPU is above threshold
            await monitor.throttleIfNeeded()
            let batchSize = monitor.recommendedConcurrency(max: maxConcurrent)
            let batch = Array(pending.prefix(batchSize))
            await withTaskGroup(of: Void.self) { group in
                for att in batch {
                    group.addTask {
                        await Self.indexAttachment(att, database: db, messageService: service, accountID: acctID)
                    }
                }
            }
            if let onProgress = onProgressUpdate {
                await onProgress()
            }
            try? await Task.sleep(for: monitor.recommendedDelay(base: .milliseconds(200)))
            pending = await db.pendingAttachments(limit: maxConcurrent, accountID: acctID)
        }
    }

    // MARK: - Index single attachment (static, runs off-actor)

    private static func indexAttachment(
        _ att: IndexedAttachment,
        database: AttachmentDatabase,
        messageService: any MessageFetching,
        accountID: String
    ) async {
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
                await database.updateIndexedContent(id: att.id, text: text, embedding: embedding, status: .indexed)
                Self.logger.info("Indexed: \(att.filename, privacy: .private)")
            case .unsupported:
                await database.updateIndexedContent(id: att.id, text: nil, embedding: nil, status: .unsupported)
                Self.logger.info("Unsupported: \(att.filename, privacy: .private)")
            }
        } catch {
            await database.incrementRetry(id: att.id)
            Self.logger.error("Failed: \(att.filename, privacy: .private) — \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Active Scan (queries API for messages with attachments)

    private var isScanning = false

    /// Max messages to scan per session (rate limiter for API calls).
    private let scanLimit = 3000

    /// Computes the cutoff date based on user's `attachmentScanMonths` setting.
    /// Returns nil if the setting is 0 (unlimited / all time).
    private var scanCutoffDate: Date? {
        let months = UserDefaults.standard.integer(forKey: UserDefaultsKey.attachmentScanMonths)
        guard months > 0 else { return nil } // 0 (not set) or -1 = all time
        return Calendar.current.date(byAdding: .month, value: -months, to: Date())
    }

    /// Returns true if the message ID is known-processed: checks in-memory cache first, DB on miss.
    private func isProcessed(_ id: String) async -> Bool {
        if processedIDCache.contains(id) { return true }
        let inDB = await database.isMessageScanned(id: id, accountID: accountID)
        if inDB { processedIDCache.insert(id) }
        return inDB
    }

    /// Scans the account for messages with attachments using `has:attachment` query.
    /// Respects the user's scan depth setting (date-based cutoff).
    /// Persists scan progress so it can resume from where it left off on next launch.
    /// Safe to call multiple times — skips if already scanning.
    func scanForAttachments() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let service = messageService
        let acctID = accountID
        let db = database
        let monitor = cpuMonitor
        let cutoffDate = scanCutoffDate

        // Build query with date filter if applicable
        var query = "has:attachment"
        if let cutoff = cutoffDate {
            query += " after:\(cutoff.formattedGmailQuery)"
        }

        // Load persisted scan state
        let scanState = await db.loadScanState(accountID: acctID)
        let previouslyComplete = scanState?.isComplete ?? false
        // If scan was previously complete, start from page 1 to catch new messages
        // Otherwise resume from saved pageToken
        var pageToken: String? = previouslyComplete ? nil : scanState?.pageToken
        var totalDiscovered = 0
        var totalScanned = 0
        var reachedCutoff = false

        do {
            repeat {
                let list = try await service.listMessages(
                    accountID: acctID,
                    labelIDs: [],
                    query: query,
                    pageToken: pageToken,
                    maxResults: 50
                )
                let refs = list.messages ?? []
                pageToken = list.nextPageToken

                guard !refs.isEmpty else { break }
                totalScanned += refs.count

                // Filter out already-scanned messages (cache + DB fallback)
                var toScan: [GmailMessageRef] = []
                for ref in refs {
                    if await !isProcessed(ref.id) {
                        toScan.append(ref)
                    }
                }

                // If scan was previously complete and entire page is already known,
                // we've caught up with new messages — stop scanning
                if previouslyComplete && toScan.isEmpty {
                    break
                }

                // Mark all page IDs as seen in cache + persist to DB
                let newIDs = refs.map(\.id)
                for id in newIDs { processedIDCache.insert(id) }
                await db.markMessagesScanned(newIDs, accountID: acctID)

                if !toScan.isEmpty {
                    // Fetch in adaptive chunks based on CPU pressure
                    let cpuUsage = monitor.processCPUUsage()
                    let chunkSize = cpuUsage > 100 ? 5 : cpuUsage > 75 ? 10 : cpuUsage > 50 ? 20 : toScan.count
                    for chunkStart in stride(from: 0, to: toScan.count, by: chunkSize) {
                        await monitor.throttleIfNeeded()
                        let chunk = Array(toScan[chunkStart..<min(chunkStart + chunkSize, toScan.count)])
                        let (messages, _) = try await service.getMessages(
                            ids: chunk.map(\.id),
                            accountID: acctID,
                            format: "full"
                        )

                        // Check if any message is older than the cutoff date
                        if let cutoff = cutoffDate,
                           let oldest = messages.compactMap(\.date).min(),
                           oldest < cutoff {
                            reachedCutoff = true
                        }

                        totalDiscovered += messages.count
                        await registerFromFullMessages(messages: messages)
                        if chunkStart + chunkSize < toScan.count {
                            try await Task.sleep(for: monitor.recommendedDelay(base: .milliseconds(300)))
                        }
                    }
                    Self.logger.info("Scanned page: \(totalDiscovered, privacy: .public) messages with attachments (total scanned: \(totalScanned, privacy: .public))")
                }

                // Persist scan progress after each page
                await db.saveScanState(accountID: acctID, pageToken: pageToken, isComplete: false)

                // Pace between pages — hard gate + adaptive delay
                await monitor.throttleIfNeeded()
                try await Task.sleep(for: monitor.recommendedDelay(base: .milliseconds(500)))

            } while pageToken != nil && totalScanned < scanLimit && !reachedCutoff

            // Mark scan as complete if we exhausted all pages or reached date cutoff
            let isComplete = pageToken == nil || reachedCutoff || (previouslyComplete && totalScanned > 0)
            await db.saveScanState(accountID: acctID, pageToken: nil, isComplete: isComplete)

            if totalDiscovered > 0 {
                let depthLabel = cutoffDate.map { "\($0.formatted(.dateTime.month().year()))" } ?? "all time"
                Self.logger.info("Scan complete: \(totalDiscovered, privacy: .public) new messages out of \(totalScanned, privacy: .public) scanned (depth: \(depthLabel, privacy: .public))")
            }
        } catch {
            // On error, the current pageToken is already saved from the last successful page
            Self.logger.error("Scan failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Register from full-format messages (thread detail)

    /// Register attachments from full-format messages (has body). Also enriches existing records.
    func registerFromFullMessages(messages: [GmailMessage]) async {
        var newCount = 0
        for message in messages {
            let parts = message.attachmentParts
            guard !parts.isEmpty else { continue }
            let alreadySeen = processedIDCache.contains(message.id)

            let labels = message.labelIds ?? []
            let direction: IndexedAttachment.Direction = labels.contains(GmailSystemLabel.sent) ? .sent : .received
            let sender = GmailDataTransformer.parseContactCore(message.from)
            let senderEmail: String? = sender.email.isEmpty ? nil : sender.email
            let senderName: String? = sender.name.isEmpty ? nil : sender.name
            let rawBody = message.plainBody ?? message.snippet
            let body = rawBody.map { String($0.prefix(5000)) }

            for part in parts {
                guard let attachmentId = part.body?.attachmentId else { continue }
                let id = "\(message.id)_\(attachmentId)"
                if await database.exists(id: id) {
                    // Only enrich body if this message wasn't already fully processed
                    if !alreadySeen, let body = body { await database.updateEmailBody(id: id, body: body) }
                    continue
                }
                let name = part.filename ?? "attachment"
                let ext = (name as NSString).pathExtension
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
                await database.insertAttachment(indexed)
                newCount += 1
            }
            processedIDCache.insert(message.id)
        }
        if let onProgress = onProgressUpdate { await onProgress() }
        if newCount > 0 { await processQueue() }
    }
}
