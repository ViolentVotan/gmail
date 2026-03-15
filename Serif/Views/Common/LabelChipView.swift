import SwiftUI

/// A compact pill chip for displaying an email label.
struct LabelChipView: View {
    let label: EmailLabel
    var isRemovable: Bool = false
    var onRemove: (() -> Void)? = nil
    @Environment(\.colorSchemeContrast) private var schemeContrast

    private var adjustedTextColor: Color {
        Color(hex: label.textColor).adjustedForContrast(
            against: Color(hex: label.color),
            targetRatio: Color.contrastTarget(for: schemeContrast)
        )
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(label.name)
                .font(Typography.captionSmallMedium)
                .foregroundStyle(adjustedTextColor)
                .lineLimit(1)

            if isRemovable {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(adjustedTextColor.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(hex: label.color)))
    }
}
