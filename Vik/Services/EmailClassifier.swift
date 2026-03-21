import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
internal import GRDB
private import os

@MainActor
final class EmailClassifier {
    nonisolated private static let logger = Logger(category: "EmailClassifier")
    static let shared = EmailClassifier()
    private init() {}

    private let tagCache = LRUCache<String, EmailTags>(maxSize: 500)

    /// Look up cached classification tags without triggering classification.
    func cachedTags(for messageId: String) -> EmailTags? {
        tagCache[messageId]
    }

    @concurrent func classifyBatch(_ emails: [Email], db: MailDatabase? = nil) async {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else { return }
        let model = SystemLanguageModel(useCase: .contentTagging)
        let instructions = Instructions("Classify this email with boolean tags.")
        for email in emails.prefix(10) {
            guard !Task.isCancelled else { return }
            guard let msgId = email.gmailMessageID else { continue }
            // Check in-memory cache on MainActor before doing any I/O
            let cached = await MainActor.run { tagCache[msgId] }
            guard cached == nil else { continue }
            do {
                // Check DB for persisted tags before invoking the model
                if let db {
                    let persisted = try? await db.dbPool.read { database in
                        try EmailTagRecord.fetchOne(database, key: msgId)
                    }
                    if let persisted {
                        let tags = EmailTags(
                            needsReply: persisted.needsReply, fyiOnly: persisted.fyiOnly,
                            hasDeadline: persisted.hasDeadline, financial: persisted.financial
                        )
                        await MainActor.run { tagCache[msgId] = tags }
                        continue
                    }
                }
                // Fresh session per email to prevent context bleed between classifications
                let session = LanguageModelSession(model: model, instructions: instructions)
                let body = String(email.body.cleanedForAI().prefix(5000))
                let prompt = "Subject: \(email.subject)\nFrom: \(email.sender.name)\n\n\(body)"
                let result = try await session.respond(to: prompt, generating: GeneratedEmailTags.self)
                let tags = EmailTags(
                    needsReply: result.content.needsReply, fyiOnly: result.content.fyiOnly,
                    hasDeadline: result.content.hasDeadline, financial: result.content.financial
                )
                await MainActor.run { tagCache[msgId] = tags }
                // Write to DB
                if let db {
                    try? await db.dbPool.write { database in
                        try EmailTagRecord(
                            messageId: msgId,
                            needsReply: tags.needsReply,
                            fyiOnly: tags.fyiOnly,
                            hasDeadline: tags.hasDeadline,
                            financial: tags.financial
                        ).upsert(database)
                    }
                }
            } catch {
                Self.logger.error("Failed to classify \(msgId): \(error)")
                continue
            }
        }
        #endif
    }
}
