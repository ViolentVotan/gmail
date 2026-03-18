import SwiftUI

struct SmartReplyChipsView: View {
    let suggestions: [String]
    let onSelect: (String) -> Void

    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer {
                    chipRow
                }
            }
            .padding(.vertical, 4)
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
            }
            .onChange(of: suggestions) {
                hasAppeared = false
                DispatchQueue.main.async {
                    hasAppeared = true
                }
            }
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    Text(suggestion)
                        .font(Typography.captionRegular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 280)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .modifier(SmartReplyChipBackground())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help(suggestion)
                .modifier(StaggeredChipEntrance(index: index, hasAppeared: hasAppeared, reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct StaggeredChipEntrance: ViewModifier {
    let index: Int
    let hasAppeared: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : OffsetToken.nudge)
            .animation(
                reduceMotion
                    ? nil
                    : VikAnimation.springSnappy.delay(Double(index) * DurationToken.stagger),
                value: hasAppeared
            )
    }
}

private struct SmartReplyChipBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.glassEffect(.regular.interactive(), in: .capsule)
    }
}
