import SwiftUI

/// Skeleton shimmer placeholder for content areas (email body, detail loading).
/// Displays animated bars that simulate text layout while content loads.
struct ContentShimmerView: View {
    @State private var shimmerPhase: CGFloat = -1

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
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
        }
    }

    private func shimmerRect(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.tertiary.opacity(OpacityToken.highlight))
            .frame(height: height)
            .overlay {
                shimmerOverlay
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
    }

    private var shimmerOverlay: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.08), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 120)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(x: shimmerPhase * 600)
        .allowsHitTesting(false)
    }
}
