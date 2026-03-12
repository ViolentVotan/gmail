import SwiftUI

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}
