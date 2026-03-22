import Foundation
private import GRDB

@MainActor
final class EmailContentPrefetcher {

    static let shared = EmailContentPrefetcher()
    private init() {}

    private var prefetchTask: Task<Void, Never>?
    private var lastPrefetchedThreadID: String?

    func prefetch(email: Email, accountID: String, mailDatabase: MailDatabase?) {
        guard let threadID = email.gmailThreadID,
              threadID != lastPrefetchedThreadID,
              EmailContentCache.shared.get(threadID) == nil
        else { return }

        prefetchTask?.cancel()
        lastPrefetchedThreadID = threadID

        let db = mailDatabase
        prefetchTask = Task {
            guard let db else { return }

            // Step 1: Read thread messages from DB
            let records = try? await db.dbPool.read { db in
                try MailDatabaseQueries.messagesForThread(threadID, in: db)
            }
            guard let records, !records.isEmpty, !Task.isCancelled else { return }

            let gmailMessages = records.map { $0.toGmailMessage() }
            var htmlParts: [String: PrecomputedMessageHTML] = [:]
            var trackerResult: TrackerResult?
            var resolvedHTML: [String: String] = [:]

            // Step 2: Build from preprocessed DB columns or fallback
            let latestRecord = records.last!
            let versionOK = latestRecord.preprocessingVersion == HTMLPreprocessingPipeline.currentVersion
            if versionOK, latestRecord.preprocessedHtml != nil {
                // Use DB-cached preprocessing — zero regex
                for record in records {
                    if let original = record.originalHtml {
                        htmlParts[record.gmailId] = PrecomputedMessageHTML(
                            fullHTML: record.preprocessedHtml ?? "",
                            originalHTML: original,
                            quotedHTML: record.quotedHtml
                        )
                    }
                }
                if let sanitized = latestRecord.sanitizedHtml {
                    trackerResult = TrackerResult(
                        sanitizedHTML: sanitized,
                        originalHTML: latestRecord.preprocessedHtml ?? sanitized,
                        trackers: []
                    )
                    if let latestID = records.last?.gmailId {
                        resolvedHTML[latestID] = sanitized
                    }
                }
            } else {
                // Fallback: full preprocessing pipeline
                guard !Task.isCancelled else { return }
                for msg in gmailMessages {
                    guard let html = msg.htmlBody, !html.isEmpty else { continue }
                    let result = HTMLPreprocessingPipeline.preprocess(html)
                    htmlParts[msg.id] = PrecomputedMessageHTML(
                        fullHTML: result.preprocessedHTML,
                        originalHTML: result.originalHTML,
                        quotedHTML: result.quotedHTML
                    )
                }
                if let latest = gmailMessages.last, let html = latest.htmlBody, !html.isEmpty {
                    let result = HTMLPreprocessingPipeline.preprocess(html)
                    trackerResult = TrackerResult(
                        sanitizedHTML: result.sanitizedHTML,
                        originalHTML: result.preprocessedHTML,
                        trackers: []
                    )
                    resolvedHTML[latest.id] = result.sanitizedHTML
                }
            }

            guard !Task.isCancelled else { return }

            // Step 3: Store in cache (skip CID resolution — loadThread handles it)
            EmailContentCache.shared.set(threadID, content: EmailContentCache.ThreadContent(
                messages: gmailMessages,
                htmlParts: htmlParts,
                trackerResult: trackerResult,
                resolvedMessageHTML: resolvedHTML
            ))
        }
    }

    func cancel() {
        prefetchTask?.cancel()
        lastPrefetchedThreadID = nil
    }
}
