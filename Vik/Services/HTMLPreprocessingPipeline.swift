/// Shared preprocessing pipeline used by BackgroundSyncer (sync-time),
/// EmailContentPrefetcher (selection-time), and EmailDetailViewModel (fallback).
/// All outputs are deterministic functions of the input HTML.
enum HTMLPreprocessingPipeline {
    /// Bump when HTMLPreprocessor, TrackerBlockerService, or stripQuotedHTML logic changes.
    /// Mismatched versions trigger lazy recomputation in loadThread().
    static let currentVersion = 1

    struct Result: Sendable {
        let preprocessedHTML: String
        let sanitizedHTML: String
        let originalHTML: String
        let quotedHTML: String?
        let version: Int
    }

    /// Runs the full preprocessing pipeline: strip → sanitize → quote-split.
    /// Safe to call from any isolation context (all inputs are value types).
    static func preprocess(_ bodyHTML: String) -> Result {
        guard !bodyHTML.isEmpty else {
            return Result(
                preprocessedHTML: "",
                sanitizedHTML: "",
                originalHTML: "",
                quotedHTML: nil,
                version: currentVersion
            )
        }
        let preprocessed = HTMLPreprocessor.strip(bodyHTML)
        let trackerResult = TrackerBlockerService.shared.sanitize(html: preprocessed)
        let parts = GmailThreadMessageView.stripQuotedHTML(preprocessed)
        return Result(
            preprocessedHTML: preprocessed,
            sanitizedHTML: trackerResult.sanitizedHTML,
            originalHTML: parts.original,
            quotedHTML: parts.quoted,
            version: currentVersion
        )
    }
}
