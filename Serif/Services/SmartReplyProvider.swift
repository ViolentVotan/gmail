import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct SmartReplies {
    @Guide(description: "2-3 short, contextual reply options for this email. Each should be a complete sentence or two, matching a professional tone.")
    var replies: [String]
}
#endif

@MainActor
final class SmartReplyProvider {
    static let shared = SmartReplyProvider()
    private init() {}

    private var cache: [String: [String]] = [:]

    func cachedReplies(for threadId: String) -> [String]? {
        cache[threadId]
    }

    func invalidate(threadId: String) {
        cache.removeValue(forKey: threadId)
    }

    func generateReplies(subject: String, senderName: String, body: String, threadId: String) async -> [String] {
        if let cached = cache[threadId] { return cached }

        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            do {
                guard SystemLanguageModel.default.availability == .available else { return [] }
                let instructions = Instructions("""
                Generate 2-3 short reply suggestions for the email below. \
                Each reply should be 1-2 sentences, professional but friendly. \
                Vary the tone: one positive/agreeable, one asking for clarification, one brief acknowledgment.
                """)
                let session = LanguageModelSession(instructions: instructions)
                let truncatedBody = String(body.cleanedForAI().prefix(10000))
                let prompt = "From: \(senderName)\nSubject: \(subject)\n\n\(truncatedBody)"
                let response = try await session.respond(to: prompt, generating: SmartReplies.self)
                let replies = Array(response.content.replies.prefix(3))
                cache[threadId] = replies
                return replies
            } catch { return [] }
            #else
            return []
            #endif
        } else { return [] }
    }
}
