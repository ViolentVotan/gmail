import SwiftUI

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(.quinary, in: .rect(cornerRadius: CornerRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .stroke(.separator, lineWidth: 0.5)
            )
    }
}

struct CompactCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(.quinary, in: .rect(cornerRadius: CornerRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .stroke(.separator, lineWidth: 0.5)
            )
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }

    func compactCardStyle() -> some View {
        modifier(CompactCardStyle())
    }
}
