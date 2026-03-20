import SwiftUI

enum SuggestionChipIcon {
    case appleIntelligence
}

enum SuggestionChipStyle {
    case standard
    case aiGradient
}

struct SuggestionChipRow: View {
    let suggestions: [String]
    var icon: SuggestionChipIcon?
    var style: SuggestionChipStyle = .standard
    let onSelect: (String) -> Void

    @State private var visibleCount = 0
    @State private var hoveredIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let aiGradient = LinearGradient(
        colors: [Color(hex: "#6E6CE8"), Color(hex: "#54C0F0"), Color(hex: "#E8754A")],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer {
                    chipContent
                }
            }
            .onAppear { animateEntrance() }
            .onChange(of: suggestions) { _, _ in animateEntrance() }
        }
    }

    private var chipContent: some View {
        HStack(spacing: 8) {
            if icon == .appleIntelligence {
                Image(systemName: "apple.intelligence")
                    .font(Typography.subheadRegular)
                    .foregroundStyle(Self.aiGradient)
                    .opacity(visibleCount > 0 ? 1 : 0)
                    .scaleEffect(visibleCount > 0 ? 1 : 0.5)
            }

            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                chipButton(suggestion: suggestion, index: index)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    private func chipButton(suggestion: String, index: Int) -> some View {
        Button {
            onSelect(suggestion)
        } label: {
            Text(suggestion)
                .font(style == .aiGradient ? Typography.subheadRegular : Typography.captionRegular)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: style == .standard ? 280 : .infinity)
                .foregroundStyle(.primary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .contentShape(.rect)
                .glassEffect(.regular.interactive(), in: .capsule)
                .overlay {
                    if style == .aiGradient {
                        Capsule()
                            .strokeBorder(Self.aiGradient, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .scaleEffect(reduceMotion ? 1.0 : (hoveredIndex == index ? ScaleToken.rowHover : 1.0))
        .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: hoveredIndex)
        .onHover { hovering in
            hoveredIndex = hovering ? index : nil
        }
        .help(suggestion)
        .accessibilityHint("Insert this reply suggestion")
        .opacity(index < visibleCount ? 1 : 0)
        .offset(y: index < visibleCount ? 0 : OffsetToken.nudge)
    }

    private func animateEntrance() {
        visibleCount = 0
        guard !suggestions.isEmpty else { return }
        if reduceMotion {
            visibleCount = suggestions.count
        } else {
            let maxStagger = min(suggestions.count, 10)
            for i in 0..<suggestions.count {
                let delay = Double(min(i, maxStagger - 1)) * DurationToken.stagger
                withAnimation(VikAnimation.springSnappy.delay(delay)) {
                    visibleCount = i + 1
                }
            }
        }
    }
}
