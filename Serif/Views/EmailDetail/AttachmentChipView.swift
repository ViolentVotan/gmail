import SwiftUI

struct AttachmentChipView: View {
    let attachment: Attachment
    var onPreview: (() -> Void)?
    var onDownload: (() -> Void)?

    @State private var isHovered = false
    @State private var isDownloadHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.fileType.rawValue)
                .font(.system(size: 13))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !attachment.size.isEmpty {
                    Text(attachment.size)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            // Fixed placeholder to reserve space for the download icon
            Color.clear.frame(width: 28)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.separatorColor), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if attachment.fileType.isPreviewable {
                onPreview?()
            } else {
                onDownload?()
            }
        }
        .overlay(alignment: .trailing) {
            Button {
                onDownload?()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isDownloadHovered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Download")
            .opacity(isHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
            .onHover { isDownloadHovered = $0 }
            .padding(.trailing, 4)
        }
        .onHover { isHovered = $0 }
    }
}
