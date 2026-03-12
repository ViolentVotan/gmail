import Foundation

/// Wraps SummaryService calls so that EmailHoverSummaryView stays free of direct service access.
@Observable
@MainActor
final class EmailSummaryViewModel {
    private(set) var displayedText = ""
    private(set) var isStreaming = true
    private(set) var isAISummary = false

    private var streamTask: Task<Void, Never>?

    func startStreaming(for email: Email) {
        streamTask = Task {
            let stream = SummaryService.shared.summary(for: email)
            for await text in stream {
                guard !Task.isCancelled else { return }
                displayedText = text
            }
            isStreaming = false
            isAISummary = SummaryService.shared.isAIGenerated(for: email)
        }
    }

    func cancelStreaming() {
        streamTask?.cancel()
    }
}
