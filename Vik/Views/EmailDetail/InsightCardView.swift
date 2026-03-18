#if canImport(FoundationModels)
import SwiftUI

@available(macOS 26.0, *)
struct InsightCardView: View {
    let insight: EmailInsightSnapshot?

    var body: some View {
        Group {
            if let insight, hasContent(insight) {
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
                                        .foregroundStyle(SemanticColor.warning)
                                    Text(action)
                                        .font(Typography.captionRegular)
                                        .foregroundStyle(.primary)
                                }
                            }
                            if let deadline = insight.deadline {
                                HStack(spacing: 4) {
                                    Image(systemName: "calendar.badge.clock")
                                        .foregroundStyle(SemanticColor.warning)
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
                                    .background(sentimentColor(sentiment).opacity(OpacityToken.highlight), in: .capsule)
                                    .foregroundStyle(sentimentColor(sentiment))
                                    .glassEffect(.regular, in: .capsule)
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
        .animation(VikAnimation.springSnappy, value: insight?.summary)
    }

    private func hasContent(_ snapshot: EmailInsightSnapshot) -> Bool {
        snapshot.summary != nil ||
        snapshot.actionNeeded != nil ||
        snapshot.deadline != nil ||
        snapshot.sentiment != nil
    }

    private func sentimentColor(_ sentiment: String) -> Color {
        switch sentiment.lowercased() {
        case "positive": return SemanticColor.success
        case "negative": return SemanticColor.error
        case "urgent": return SemanticColor.warning
        default: return .secondary
        }
    }
}
#endif
