import Foundation

/// Wraps SummaryService calls so that EmailHoverSummaryView stays free of direct service access.
@Observable
@MainActor
final class EmailSummaryViewModel {
    private(set) var displayedText = ""
    private(set) var isStreaming = true
    private(set) var isAISummary = false
    private(set) var insight: EmailInsightSnapshot?

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var insightTask: Task<Void, Never>?

    deinit {
        streamTask?.cancel()
        insightTask?.cancel()
    }

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

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            insightTask = Task {
                let stream = SummaryService.shared.insight(for: email)
                for await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    insight = snapshot
                }
            }
        }
        #endif
    }

    func cancelStreaming() {
        streamTask?.cancel()
        insightTask?.cancel()
    }
}
