import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import GRDB
private import os

@MainActor
final class EmailClassifier {
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.serif", category: "EmailClassifier")
    static let shared = EmailClassifier()
    private init() {}

    private var tagCache: [String: EmailTags] = [:]

    func cachedTags(for messageId: String) -> EmailTags? {
        tagCache[messageId]
    }

    func classifyBatch(_ emails: [Email], db: MailDatabase? = nil) async {
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            guard SystemLanguageModel.default.availability == .available else { return }
            for email in emails.prefix(10) {
                guard let msgId = email.gmailMessageID, tagCache[msgId] == nil else { continue }
                do {
                    // Check DB for persisted tags before invoking the model
                    if let db {
                        let persisted = try? await db.dbPool.read { database in
                            try EmailTagRecord.fetchOne(database, key: msgId)
                        }
                        if let persisted {
                            tagCache[msgId] = EmailTags(
                                needsReply: persisted.needsReply, fyiOnly: persisted.fyiOnly,
                                hasDeadline: persisted.hasDeadline, financial: persisted.financial
                            )
                            continue
                        }
                    }
                    let instructions = Instructions("Classify this email with boolean tags.")
                    let session = LanguageModelSession(instructions: instructions)
                    let body = String(email.body.cleanedForAI().prefix(5000))
                    let prompt = "Subject: \(email.subject)\nFrom: \(email.sender.name)\n\n\(body)"
                    let result = try await session.respond(to: prompt, generating: GeneratedEmailTags.self)
                    let tags = EmailTags(
                        needsReply: result.content.needsReply, fyiOnly: result.content.fyiOnly,
                        hasDeadline: result.content.hasDeadline, financial: result.content.financial
                    )
                    tagCache[msgId] = tags
                    if tagCache.count > 500 {
                        let removeCount = tagCache.count / 4
                        for key in tagCache.keys.prefix(removeCount) {
                            tagCache.removeValue(forKey: key)
                        }
                    }
                    // Write to DB
                    if let db {
                        try? await db.dbPool.write { database in
                            try EmailTagRecord(
                                messageId: msgId,
                                needsReply: tags.needsReply,
                                fyiOnly: tags.fyiOnly,
                                hasDeadline: tags.hasDeadline,
                                financial: tags.financial,
                                classifiedAt: Date().timeIntervalSince1970,
                                classifierVersion: nil
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
}
