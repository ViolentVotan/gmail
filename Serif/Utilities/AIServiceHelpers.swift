import Foundation

/// Shared helpers used across AI service classes (SummaryService, QuickReplyService,
/// SmartReplyProvider, LabelSuggestionService) to eliminate duplication.
enum AIServiceHelpers {
    /// Returns a stable cache key for an email, preferring the Gmail message ID.
    static func cacheKey(for email: Email) -> String {
        email.gmailMessageID ?? email.id.uuidString
    }

    /// Returns a locale instruction string for AI prompts.
    /// Empty string for en_US; otherwise tells the model the user's locale.
    static func localeInstructions(for locale: Locale = .current) -> String {
        if Locale.Language(identifier: "en_US").isEquivalent(to: locale.language) {
            return ""
        }
        return "The person's locale is \(locale.identifier)."
    }

    /// Extracts and cleans the email body (or preview fallback) for AI consumption.
    static func cleanedPreview(from email: Email) -> String {
        let text = email.body.isEmpty ? email.preview : email.body
        return text.cleanedForAI()
    }
}
