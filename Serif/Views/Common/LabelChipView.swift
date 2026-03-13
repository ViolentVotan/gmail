import SwiftUI

/// A compact pill chip for displaying an email label.
struct LabelChipView: View {
    let label: EmailLabel
    var isRemovable: Bool = false
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            Text(label.name)
                .font(Typography.captionSmallMedium)
                .foregroundStyle(Color(hex: label.textColor))
                .lineLimit(1)

            if isRemovable {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(hex: label.textColor).opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(hex: label.color)))
    }
}
