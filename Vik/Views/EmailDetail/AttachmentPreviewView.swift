import SwiftUI
import PDFKit
import AppKit

// MARK: - AttachmentPreviewView

struct AttachmentPreviewView: View {
    let data: Data
    let fileName: String
    let fileType: Attachment.FileType
    var onDownload: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var zoomScale: CGFloat = 1.0
    @State private var decodedImage: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            previewToolbar
            Divider().background(Color(.separatorColor))
            previewContent
        }
        .task(id: data) {
            let decoded = await Task.detached { NSImage(data: data) }.value
            decodedImage = decoded
        }
    }

    // MARK: - Toolbar

    private var previewToolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(Typography.calloutSemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(fileType.label)
                    .font(Typography.captionRegular)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if fileType == .image {
                HStack(spacing: 4) {
                    Button {
                        withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                            zoomScale = max(0.25, zoomScale - 0.25)
                        }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Zoom out")
                    .accessibilityLabel("Zoom out")

                    Text("\(Int(zoomScale * 100))%")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 36)

                    Button {
                        withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                            zoomScale = min(4.0, zoomScale + 0.25)
                        }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Zoom in")
                    .accessibilityLabel("Zoom in")

                    Button {
                        withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) { zoomScale = 1.0 }
                    } label: {
                        Image(systemName: "1.magnifyingglass")
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Reset zoom")
                    .accessibilityLabel("Reset zoom")

                    Divider().frame(height: 16).padding(.horizontal, 4)
                }
            }

            Button {
                onDownload?()
            } label: {
                Label("Save", systemImage: "arrow.down.circle")
                    .font(Typography.subhead)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs)
            }
            .buttonStyle(.borderedProminent)
            .help("Save to disk")
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    // MARK: - Content router

    @ViewBuilder
    private var previewContent: some View {
        switch fileType {
        case .image:
            imagePreview
        case .pdf:
            pdfPreview
        case .code:
            textPreview
        default:
            unsupportedPreview
        }
    }

    // MARK: - Image

    // GeometryReader is intentionally used here instead of containerRelativeFrame because
    // the image fitting calculation requires both width and height of the viewport simultaneously
    // to compute the aspect-ratio-preserving fittedScale, which containerRelativeFrame cannot express.
    private var imagePreview: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                if let nsImage = decodedImage {
                    // Fit the image inside the available viewport at scale 1,
                    // then multiply by zoomScale for user zoom.
                    let natural = nsImage.size
                    let fittedScale = min(
                        (geo.size.width - 48) / max(natural.width, 1),
                        (geo.size.height - 48) / max(natural.height, 1),
                        1.0
                    )
                    let displayW = natural.width  * fittedScale * zoomScale
                    let displayH = natural.height * fittedScale * zoomScale

                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: displayW, height: displayH)
                        .padding(Spacing.xl)
                        .animation(reduceMotion ? nil : VikAnimation.springSnappy, value: zoomScale)
                } else {
                    corruptedFileView
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }

    // MARK: - PDF

    private var pdfPreview: some View {
        PDFKitView(data: data)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Text / Code

    private var textPreview: some View {
        ScrollView {
            if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                Text(text)
                    .font(Typography.subheadMonospaced)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.xl)
            } else {
                corruptedFileView
            }
        }
    }

    // MARK: - Unsupported

    private var unsupportedPreview: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 72, height: 72)
                Image(systemName: fileType.rawValue)
                    .font(Typography.emptyStateMediumIcon)
                    .foregroundStyle(.tertiary)
            }

            Text("This file type cannot be previewed")
                .font(Typography.calloutMedium)
                .foregroundStyle(.secondary)

            Text(fileName)
                .font(Typography.subheadRegular)
                .foregroundStyle(.tertiary)

            Button {
                onDownload?()
            } label: {
                Label("Download file", systemImage: "arrow.down.circle.fill")
                    .font(Typography.bodyMedium)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.md)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Error state

    private var corruptedFileView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(Typography.emptyStateIcon)
                .foregroundStyle(.tertiary)
            Text("Could not render this file")
                .font(Typography.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - PDFKitView (NSViewRepresentable)

private struct PDFKitView: NSViewRepresentable {
    let data: Data

    final class Coordinator {
        var lastData: Data?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        if let document = PDFDocument(data: data) {
            view.document = document
        }
        context.coordinator.lastData = data
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        guard data != context.coordinator.lastData else { return }
        context.coordinator.lastData = data
        if let document = PDFDocument(data: data) {
            nsView.document = document
        }
    }
}

// MARK: - Helpers

extension Attachment.FileType {
    /// True for types we can render inline.
    var isPreviewable: Bool {
        switch self {
        case .image, .pdf, .code: return true
        default: return false
        }
    }
}
