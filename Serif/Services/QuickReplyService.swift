import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class QuickReplyService {
    static let shared = QuickReplyService()

    private var cache: [String: [String]] = [:]

    private init() {}

    func cachedReplies(for email: Email) -> [String]? {
        guard let key = cacheKey(for: email) else { return nil }
        return cache[key]
    }

    func generateReplies(for email: Email) async -> [String] {
        if let key = cacheKey(for: email), let cached = cache[key] {
            return cached
        }

        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            return await generateWithFoundationModels(email: email)
            #else
            return []
            #endif
        } else {
            return []
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generateWithFoundationModels(email: Email) async -> [String] {
        guard SystemLanguageModel.default.availability == .available else { return [] }

        do {
            let localePhrase = Self.localeInstructions()
            let instructions = Instructions("""
            You are an email assistant inside a macOS email client. \
            The user has opened an email and you must suggest quick replies. \
            Rules:
            - Generate 1 to 3 short reply suggestions (max 10 words each).
            - Match the language of the email body when possible. \
            If the email is in a supported language, reply in that language.
            - Adapt tone to the email (formal/informal).
            - Return each suggestion on a separate line, prefixed with a number and a dot (e.g. "1. Thanks, I'll take a look.").
            - No extra text, just the numbered suggestions.
            \(localePhrase)
            """)
            let session = LanguageModelSession(instructions: instructions)

            var context = "From: \(email.sender.name)"
            if !email.recipients.isEmpty {
                let to = email.recipients.prefix(3).map(\.name).joined(separator: ", ")
                context += "\nTo: \(to)"
            }
            context += "\nSubject: \(email.subject)"

            let body = cleanedPreview(from: email)
            let prompt = """
            \(context)

            \(body)
            """

            let response = try await session.respond(to: prompt)
            let replies = parseReplies(from: response.content)

            if let key = cacheKey(for: email) {
                cache[key] = replies
                if cache.count > 200 { cache.removeAll() }
            }
            return replies
        } catch is CancellationError {
            return []
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .unsupportedLanguageOrLocale, .refusal:
                // Language not supported or model refused — fall back silently
                return []
            default:
                return []
            }
        } catch {
            return []
        }
    }

    #endif

    private static func localeInstructions(for locale: Locale = .current) -> String {
        if Locale.Language(identifier: "en_US").isEquivalent(to: locale.language) {
            return ""
        }
        return "The person's locale is \(locale.identifier)."
    }

    private static let refusalPatterns: [String] = [
        "cannot fulfill",
        "can't fulfill",
        "cannot generate",
        "can't generate",
        "not able to",
        "i'm sorry",
        "i cannot",
        "i can't",
        "unable to",
        "not supported",
    ]

    private func parseReplies(from text: String) -> [String] {
        let lower = text.lowercased()
        if Self.refusalPatterns.contains(where: { lower.contains($0) }) {
            return []
        }

        let unwanted = CharacterSet(charactersIn: ".\"\u{201C}\u{201D}")
            .union(.whitespaces)

        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { line in
                var cleaned = line
                // Strip leading "1. ", "2) ", "- " etc.
                if let match = cleaned.range(of: #"^\d+[\.\)]\s*"#, options: .regularExpression) {
                    cleaned = String(cleaned[match.upperBound...])
                } else if cleaned.hasPrefix("- ") {
                    cleaned = String(cleaned.dropFirst(2))
                }
                // Trim dots, quotes, whitespace from both ends
                cleaned = cleaned.trimmingCharacters(in: unwanted)
                return cleaned.isEmpty ? nil : cleaned
            }
            .prefix(3)
            .map { String($0) }
    }

    private func cleanedPreview(from email: Email) -> String {
        let text = email.body.isEmpty ? email.preview : email.body
        return text.cleanedForAI()
    }

    private func cacheKey(for email: Email) -> String? {
        email.gmailMessageID ?? email.id.uuidString
    }
}
