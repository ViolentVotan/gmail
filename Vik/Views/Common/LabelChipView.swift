import SwiftUI

/// A compact pill chip for displaying an email label.
struct LabelChipView: View {
    let label: EmailLabel
    var isRemovable: Bool = false
    var onRemove: (() -> Void)? = nil

    private let chipColor: Color
    private let textForeground: Color

    init(label: EmailLabel, isRemovable: Bool = false, onRemove: (() -> Void)? = nil) {
        self.label = label
        self.isRemovable = isRemovable
        self.onRemove = onRemove
        self.chipColor = Color(hex: label.color)
        self.textForeground = label.textColor.isEmpty ? Color.primary : Color(hex: label.textColor)
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(label.name)
                .font(Typography.captionSmallMedium)
                .foregroundStyle(textForeground)
                .lineLimit(1)

            if isRemovable {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark")
                        .font(Typography.captionSmallBold)
                        .foregroundStyle(textForeground.opacity(OpacityToken.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(label.name) label")
                .help("Remove \(label.name)")
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(chipColor.opacity(OpacityToken.highlight), in: .capsule)
        .glassEffect(.regular, in: .capsule)
    }
}
