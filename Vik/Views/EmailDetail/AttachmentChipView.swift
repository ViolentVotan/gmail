import SwiftUI
import AppKit

struct AttachmentChipView: View {
    let attachment: Attachment
    let isDownloading: Bool
    let siblingCount: Int
    var onPreview: (() -> Void)?
    var onDownload: (() -> Void)?
    var onOpen: (() -> Void)?
    var onSaveAll: (() -> Void)?
    var onShare: ((NSView) -> Void)?
    var onDragProvider: (() -> NSItemProvider)?

    @State private var isHovered = false
    @State private var isDownloadHovered = false
    @State private var shareAnchorView: NSView?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if isDownloading {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .scale))
            } else {
                Image(systemName: attachment.fileType.rawValue)
                    .font(Typography.body)
                    .foregroundStyle(.tint)
                    .transition(.opacity.combined(with: .scale))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(Typography.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !attachment.size.isEmpty {
                    Text(attachment.size)
                        .font(Typography.captionSmallRegular)
                        .foregroundStyle(.tertiary)
                }
            }

            Color.clear.frame(width: 28)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .glassEffect(
            isHovered ? .regular.interactive() : .identity,
            in: .rect(cornerRadius: CornerRadius.sm)
        )
        .opacity(isDownloading ? 0.7 : 1.0)
        .scaleEffect(reduceMotion ? 1.0 : (isHovered ? ScaleToken.hover : 1.0))
        .animation(VikAnimation.springSnappy, value: isHovered)
        .animation(VikAnimation.springSnappy, value: isDownloading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onOpen?()
        }
        .onTapGesture(count: 1) {
            if attachment.fileType.isPreviewable {
                onPreview?()
            } else {
                onDownload?()
            }
        }
        .onDrag {
            onDragProvider?() ?? NSItemProvider()
        }
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: CornerRadius.sm))
        .overlay(alignment: .trailing) {
            Button {
                onDownload?()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(Typography.subheadRegular)
                    .foregroundStyle(isDownloadHovered ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect.inset(by: -8))
            }
            .buttonStyle(.plain)
            .help("Download")
            .opacity(isHovered && !isDownloading ? 1 : 0)
            .disabled(isDownloading)
            .animation(VikAnimation.springSnappy, value: isHovered)
            .onHover { isDownloadHovered = $0 }
            .padding(.trailing, 4)
        }
        .background {
            ShareSheetAnchor { view in shareAnchorView = view }
                .frame(width: 0, height: 0)
        }
        .onHover { isHovered = $0 }
        .contextMenu { contextMenuContent }
        .accessibilityLabel("Attachment: \(attachment.name), \(attachment.size)")
        .accessibilityHint(attachment.fileType.isPreviewable ? "Click to preview, double-click to open" : "Click to download, double-click to open")
        .accessibilityAction(named: "Open in default app") { onOpen?() }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        if attachment.fileType.isPreviewable {
            Button {
                onPreview?()
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
        }

        Button {
            onOpen?()
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }

        Divider()

        Button {
            onDownload?()
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }

        if siblingCount > 1 {
            Button {
                onSaveAll?()
            } label: {
                Label("Save All Attachments", systemImage: "arrow.down.doc")
            }
        }

        Divider()

        Button {
            if let view = shareAnchorView {
                onShare?(view)
            }
        } label: {
            Label("Share...", systemImage: "square.and.arrow.up")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(attachment.name, forType: .string)
        } label: {
            Label("Copy Filename", systemImage: "doc.on.doc")
        }
    }
}

// MARK: - Share Sheet Anchor

private struct ShareSheetAnchor: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onView(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
