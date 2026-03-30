import SwiftUI

/// Skeleton shimmer placeholder for content areas (email body, detail loading).
/// Displays animated bars that simulate text layout while content loads.
struct ContentShimmerView: View {
    @State private var shimmerPhase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            shimmerRect(height: 10)
                .padding(.trailing, 40)
            shimmerRect(height: 10)
            shimmerRect(height: 10)
                .padding(.trailing, 80)
            Spacer().frame(height: 4)
            shimmerRect(height: 10)
            shimmerRect(height: 10)
                .padding(.trailing, 60)
            shimmerRect(height: 10)
                .padding(.trailing, 120)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .drawingGroup()
        .task {
            guard !reduceMotion, shimmerPhase < 0 else { return }
            withAnimation(VikAnimation.shimmer) {
                shimmerPhase = 1
            }
        }
    }

    private func shimmerRect(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: CornerRadius.xxs)
            .fill(.tertiary.opacity(OpacityToken.highlight))
            .frame(height: height)
            .overlay {
                shimmerOverlay
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxs))
            }
    }

    private var shimmerOverlay: some View {
        LinearGradient(
            colors: [.clear, ShimmerColor.highlight.opacity(OpacityToken.highlight), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 120)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(x: shimmerPhase * 600)
        .allowsHitTesting(false)
    }
}
