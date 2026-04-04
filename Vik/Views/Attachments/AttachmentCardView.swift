import SwiftUI

struct AttachmentCardView: View {
    let result: AttachmentSearchResult
    let isSearchActive: Bool
    let accountID: String
    var onTap: (() -> Void)?
    var onAddExclusionRule: ((String) -> Void)?
    var onViewMessage: (() -> Void)?
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let thumbCache = ThumbnailCache.shared

    private let thumbHeight: CGFloat = 80

    // MARK: - Computed

    private var fileType: Attachment.FileType {
        Attachment.FileType(rawValue: result.attachment.fileType) ?? .document
    }

    private var fileTypeIcon: String { fileType.rawValue }

    private var iconBackgroundColor: Color {
        switch fileType {
        case .image:        return FileTypeColor.image.opacity(OpacityToken.tag)
        case .pdf:          return FileTypeColor.pdf.opacity(OpacityToken.tag)
        case .spreadsheet:  return FileTypeColor.spreadsheet.opacity(OpacityToken.tag)
        case .document:     return FileTypeColor.document.opacity(OpacityToken.tag)
        case .presentation: return FileTypeColor.presentation.opacity(OpacityToken.tag)
        case .archive:      return FileTypeColor.archive.opacity(OpacityToken.tag)
        case .code:         return FileTypeColor.code.opacity(OpacityToken.tag)
        }
    }

    private var iconForegroundColor: Color {
        switch fileType {
        case .image:        return FileTypeColor.image
        case .pdf:          return FileTypeColor.pdf
        case .spreadsheet:  return FileTypeColor.spreadsheet
        case .document:     return FileTypeColor.document
        case .presentation: return FileTypeColor.presentation
        case .archive:      return FileTypeColor.archive
        case .code:         return FileTypeColor.code
        }
    }

    private var formattedSize: String {
        let size = result.attachment.size
        guard size > 0 else { return "" }
        return GmailDataTransformer.sizeString(size)
    }

    private var formattedDate: String {
        result.attachment.emailDate?.formattedDateOnly ?? ""
    }

    private var scoreColor: Color {
        if result.score > 0.7 { return SemanticColor.success }
        if result.score > 0.4 { return SemanticColor.warning }
        return SemanticColor.error
    }

    // MARK: - Body

    var body: some View {
        Button {
            onTap?()
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .accessibilityLabel(result.attachment.filename)
        .help(result.attachment.filename)
        .onHover { hovering in isHovered = hovering }
        .task(id: result.attachment.id) { thumbCache.loadIfNeeded(attachment: result.attachment, accountID: accountID) }
        .onDisappear {
            thumbCache.cancelIfNeeded(id: result.attachment.id)
        }
        .contextMenu {
            Button {
                onViewMessage?()
            } label: {
                Label("View message", systemImage: "envelope")
            }

            Button {
                onAddExclusionRule?(suggestedPattern)
            } label: {
                Label("Add exclusion rule...", systemImage: "eye.slash")
            }
        }
    }

    /// Suggests a glob pattern from the filename, e.g. "Outlook-abc123.png" → "Outlook-*"
    private var suggestedPattern: String {
        let name = result.attachment.filename
        // Try to find a prefix before a digit-run or random-looking suffix
        if let dashRange = name.range(of: "-"),
           let afterDash = name[dashRange.upperBound...].first,
           afterDash.isNumber || afterDash.isLetter {
            let prefix = String(name[...dashRange.lowerBound])
            return prefix + "*"
        }
        return name
    }

    private var cardContent: some View {
        VStack(spacing: 0) {
            thumbnailArea
            Spacer().frame(height: 10)
            filenameArea
            Spacer().frame(height: 4)
            metadataArea
            if isSearchActive { scoreArea }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .background(RoundedRectangle(cornerRadius: CornerRadius.md).fill(.background))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .strokeBorder(isHovered ? iconForegroundColor.opacity(OpacityToken.divider) : Color(.separatorColor), lineWidth: isHovered ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .scaleEffect(reduceMotion ? 1.0 : (isHovered ? ScaleToken.hover : 1.0))
        .animation(reduceMotion ? nil : VikAnimation.springSnappy, value: isHovered)
    }

    // MARK: - Subviews

    private var thumbnailArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(iconBackgroundColor)

            if let thumb = thumbCache.thumbnail(for: result.attachment.id) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: Spacing.xs) {
                    Image(systemName: fileTypeIcon)
                        .font(Typography.emptyStateMediumIcon)
                        .foregroundStyle(iconForegroundColor)
                    if !formattedSize.isEmpty {
                        Text(formattedSize)
                            .font(Typography.captionSmallMediumMonospaced)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    }

    private var filenameArea: some View {
        Text(result.attachment.filename)
            .font(Typography.subhead)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: 32, alignment: .top)
    }

    private var metadataArea: some View {
        VStack(spacing: 2) {
            Text(result.attachment.senderName ?? result.attachment.senderEmail ?? "")
                .font(Typography.captionSmallRegular)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(formattedDate)
                .font(Typography.captionSmallRegular)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
    }

    private var scoreArea: some View {
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(scoreColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text("\(Int(result.score * 100))%")
                .font(Typography.captionSmallMediumMonospaced)
                .foregroundStyle(.secondary)
        }
        .frame(height: 14)
    }
}
