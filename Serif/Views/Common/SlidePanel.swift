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
    @ScaledMetric(relativeTo: .subheadline) private var closeButtonSize: CGFloat = 24

    var body: some View {
        HStack(spacing: 0) {
            // Panel
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(title)
                        .font(Typography.title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark")
                            .font(Typography.subhead)
                            .foregroundStyle(.secondary)
                            .frame(width: closeButtonSize, height: closeButtonSize)
                    }
                    .buttonStyle(.glass)
                }
                .padding(Spacing.xl)

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
            .modifier(SlidePanelBackground())
            .elevation(.elevated)
            .offset(x: isPresented ? 0 : -(panelWidth + 60))
            .animation(SerifAnimation.springDefault, value: isPresented)

            // Tap outside to dismiss
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
        }
        .allowsHitTesting(isPresented)
    }
}

private struct SlidePanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.glassEffect(.regular, in: .rect(cornerRadius: 0))
    }
}
