import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class EmailClassifier {
    static let shared = EmailClassifier()
    private init() {}

    private var tagCache: [String: EmailTags] = [:]

    func cachedTags(for messageId: String) -> EmailTags? {
        tagCache[messageId]
    }

    func classifyBatch(_ emails: [Email]) async {
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            do {
                guard SystemLanguageModel.default.availability == .available else { return }
                for email in emails.prefix(10) {
                    guard let msgId = email.gmailMessageID, tagCache[msgId] == nil else { continue }
                    let instructions = Instructions("Classify this email with boolean tags.")
                    let session = LanguageModelSession(instructions: instructions)
                    let body = String(email.body.cleanedForAI().prefix(5000))
                    let prompt = "Subject: \(email.subject)\nFrom: \(email.sender.name)\n\n\(body)"
                    let result = try await session.respond(to: prompt, generating: GeneratedEmailTags.self)
                    tagCache[msgId] = EmailTags(
                        needsReply: result.content.needsReply, fyiOnly: result.content.fyiOnly,
                        hasDeadline: result.content.hasDeadline, financial: result.content.financial
                    )
                }
            } catch { }
            #endif
        }
    }
}
