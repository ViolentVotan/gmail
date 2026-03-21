import Foundation

/// Shared helpers used across AI service classes (SummaryService,
/// LabelSuggestionService) to eliminate duplication.
enum AIServiceHelpers {
    /// Returns a stable cache key for an email, preferring the Gmail message ID.
    static func cacheKey(for email: Email) -> String {
        email.gmailMessageID ?? email.id.uuidString
    }

    /// Extracts and cleans the email body (or preview fallback) for AI consumption.
    static func cleanedPreview(from email: Email) -> String {
        let text = email.body.isEmpty ? email.preview : email.body
        return text.cleanedForAI()
    }
}
