import SwiftUI

struct SmartReplyChipsView: View {
    let suggestions: [String]
    let onSelect: (String) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
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
                                .background(.quinary)
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 4)
        }
    }
}
