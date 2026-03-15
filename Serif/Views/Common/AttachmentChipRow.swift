import SwiftUI

struct AttachmentChipRow: View {
    @Binding var attachments: [URL]

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachments, id: \.self) { url in
                        HStack(spacing: 4) {
                            Image(systemName: url.sfSymbolIcon)
                                .font(Typography.captionRegular)
                            Text(url.lastPathComponent)
                                .font(Typography.captionRegular)
                                .lineLimit(1)
                            Button { attachments.removeAll { $0 == url } } label: {
                                Image(systemName: "xmark").font(.caption2.weight(.bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm), interactive: true)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.sm)
            }
        }
    }
}
