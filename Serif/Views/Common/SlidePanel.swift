import SwiftUI

struct SlidePanel<Content: View>: View {
    @Binding var isPresented: Bool
    let title: String
    let scrollable: Bool
    let content: Content

    init(
        isPresented: Binding<Bool>,
        title: String,
        scrollable: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self._isPresented = isPresented
        self.title = title
        self.scrollable = scrollable
        self.content = content()
    }

    @State private var panelWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            // Panel
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(.regularMaterial)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)

                Divider()

                if scrollable {
                    ScrollView { content }
                } else {
                    content
                }
            }
            .containerRelativeFrame(.horizontal) { length, _ in length * 0.25 }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelWidth = $0 }
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.12), radius: 20, x: 8, y: 0)
            .offset(x: isPresented ? 0 : -(panelWidth + 60))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isPresented)

            // Tap outside to dismiss
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
        }
        .allowsHitTesting(isPresented)
    }
}
