#if canImport(FoundationModels)
import SwiftUI

@available(macOS 26.0, *)
@Observable @MainActor
private final class InsightCardViewModel {
    private(set) var insight: EmailInsightSnapshot?
    private var insightTask: Task<Void, Never>?

    func startStreaming(for email: Email) {
        insightTask?.cancel()
        insight = nil
        insightTask = Task {
            let stream = SummaryService.shared.insight(for: email)
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                insight = snapshot
            }
        }
    }

    func cancel() {
        insightTask?.cancel()
    }
}

@available(macOS 26.0, *)
struct InsightCardView: View {
    let email: Email

    @State private var viewModel = InsightCardViewModel()

    var body: some View {
        Group {
            if let insight = viewModel.insight, hasContent(insight) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Label("Apple Intelligence", systemImage: "apple.intelligence")
                            .font(Typography.captionSmallMedium)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }

                    if let summary = insight.summary, !summary.isEmpty {
                        Text(summary)
                            .font(Typography.subheadRegular)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if insight.actionNeeded != nil || insight.deadline != nil || insight.sentiment != nil {
                        HStack(spacing: 8) {
                            if let action = insight.actionNeeded {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                    Text(action)
                                        .font(Typography.captionRegular)
                                        .foregroundStyle(.primary)
                                }
                            }
                            if let deadline = insight.deadline {
                                HStack(spacing: 4) {
                                    Image(systemName: "calendar.badge.clock")
                                        .foregroundStyle(.red)
                                    Text(deadline)
                                        .font(Typography.captionRegular)
                                        .foregroundStyle(.primary)
                                }
                            }
                            if let sentiment = insight.sentiment {
                                Text(sentiment.capitalized)
                                    .font(Typography.captionSmallMedium)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(sentimentColor(sentiment).opacity(0.15))
                                    .foregroundStyle(sentimentColor(sentiment))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                        }
                    }
                }
                .compactCardStyle()
                .accessibilityElement(children: .combine)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: viewModel.insight?.summary)
        .task(id: email.id) {
            viewModel.startStreaming(for: email)
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    private func hasContent(_ snapshot: EmailInsightSnapshot) -> Bool {
        snapshot.summary != nil ||
        snapshot.actionNeeded != nil ||
        snapshot.deadline != nil ||
        snapshot.sentiment != nil
    }

    private func sentimentColor(_ sentiment: String) -> Color {
        switch sentiment.lowercased() {
        case "positive": return .green
        case "negative": return .red
        case "urgent": return .orange
        default: return .secondary
        }
    }
}
#endif
