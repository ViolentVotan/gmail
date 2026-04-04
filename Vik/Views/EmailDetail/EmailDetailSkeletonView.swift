import SwiftUI

struct EmailDetailSkeletonView: View {
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Sender header
                HStack(spacing: 12) {
                    Circle()
                        .fill(.tertiary.opacity(animate ? 0.1 : 0.2))
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: Spacing.xsm) {
                        bar(width: 140, height: 11)
                        bar(width: 190, height: 9)
                    }
                    Spacer()
                    bar(width: 55, height: 9)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.xl)

                // Subject
                bar(width: 260, height: 16)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.xxl)

                // Body lines
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<3, id: \.self) { _ in bar(height: 11) }
                    bar(width: 220, height: 11)
                    Spacer().frame(height: 6)
                    ForEach(0..<4, id: \.self) { _ in bar(height: 11) }
                    bar(width: 160, height: 11)
                }
                .padding(.horizontal, Spacing.xl)
            }
            .drawingGroup()
        }
        .task {
            guard !reduceMotion else { return }
            withAnimation(VikAnimation.skeletonPulse) {
                animate = true
            }
        }
    }

    private func bar(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(.tertiary.opacity(animate ? 0.1 : 0.2))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}
