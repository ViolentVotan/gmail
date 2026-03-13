import SwiftUI

struct SmartReplyChipsView: View {
    let suggestions: [String]
    let onSelect: (String) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if #available(macOS 26.0, *) {
                        GlassEffectContainer {
                            chipRow
                        }
                    } else {
                        chipRow
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    Text(suggestion)
                        .font(.caption)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .modifier(SmartReplyChipBackground())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct SmartReplyChipBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.quinary)
                .clipShape(Capsule())
        }
    }
}
