import SwiftUI

/// A compact pill chip for displaying an email label.
struct LabelChipView: View {
    let label: EmailLabel
    var isRemovable: Bool = false
    var onRemove: (() -> Void)? = nil

    private var chipColor: Color { Color(hex: label.color) }

    var body: some View {
        HStack(spacing: 3) {
            Text(label.name)
                .font(Typography.captionSmallMedium)
                .foregroundStyle(chipColor)
                .lineLimit(1)

            if isRemovable {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(chipColor.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(label.name) label")
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(chipColor.opacity(OpacityToken.highlight), in: .capsule)
        .glassEffect(.regular, in: .capsule)
    }
}
