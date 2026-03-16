import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Reply Style

enum ReplyStyle {
    /// Full reply suggestions: 2-3 complete sentences, professional but friendly.
    case full
    /// Brief reply suggestions: 2-3 short phrases, max 10 words each.
    case brief
}

// MARK: - Generable Structs

#if canImport(FoundationModels)
@Generable
struct FullSmartReplies {
    @Guide(description: "2-3 short, contextual reply options for this email. Each should be a complete sentence or two, matching a professional tone.")
    var replies: [String]
}

@Generable
struct BriefSmartReplies {
    @Guide(description: "2-3 very short reply phrases for this email. Each must be at most 10 words. Match the language and tone of the email.")
    var replies: [String]
}
#endif

// MARK: - SmartReplyService

@MainActor
final class SmartReplyService {
    static let shared = SmartReplyService()
    private init() {}

    private let cache = LRUCache<String, [String]>(maxSize: 200)

    func cachedReplies(for threadId: String, style: ReplyStyle) -> [String]? {
        cache[cacheKey(threadId: threadId, style: style)]
    }

    func invalidate(threadId: String) {
        cache[cacheKey(threadId: threadId, style: .full)] = nil
        cache[cacheKey(threadId: threadId, style: .brief)] = nil
    }

    func generateReplies(
        subject: String,
        senderName: String,
        body: String,
        threadId: String,
        style: ReplyStyle
    ) async -> [String] {
        let key = cacheKey(threadId: threadId, style: style)
        if let cached = cache[key] { return cached }

        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else { return [] }

        do {
            let localePhrase = AIServiceHelpers.localeInstructions()
            let truncatedBody = String(body.cleanedForAI().prefix(10000))
            let prompt = "From: \(senderName)\nSubject: \(subject)\n\n\(truncatedBody)"

            let replies: [String]
            switch style {
            case .full:
                replies = try await generateFullReplies(prompt: prompt, localePhrase: localePhrase)
            case .brief:
                replies = try await generateBriefReplies(prompt: prompt, localePhrase: localePhrase)
            }

            cache[key] = replies
            return replies
        } catch is CancellationError {
            return []
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .unsupportedLanguageOrLocale, .refusal:
                return []
            default:
                return []
            }
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    // MARK: - Private

    private func cacheKey(threadId: String, style: ReplyStyle) -> String {
        switch style {
        case .full: "\(threadId)-full"
        case .brief: "\(threadId)-brief"
        }
    }

    #if canImport(FoundationModels)
    private func generateFullReplies(prompt: String, localePhrase: String) async throws -> [String] {
        let instructions = Instructions("""
        Generate 2-3 short reply suggestions for the email below. \
        Each reply should be 1-2 sentences, professional but friendly. \
        Match the language of the email when possible. \
        Vary the tone: one positive/agreeable, one asking for clarification, one brief acknowledgment. \
        \(localePhrase)
        """)
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: FullSmartReplies.self)
        return Array(response.content.replies.prefix(3))
    }

    private func generateBriefReplies(prompt: String, localePhrase: String) async throws -> [String] {
        let instructions = Instructions("""
        Generate 2-3 very short reply suggestions for the email below. \
        Each reply must be at most 10 words. \
        Match the language of the email when possible. \
        Adapt tone to the email (formal/informal). \
        \(localePhrase)
        """)
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: BriefSmartReplies.self)
        return Array(response.content.replies.prefix(3))
    }
    #endif
}
