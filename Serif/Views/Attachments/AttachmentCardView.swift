import SwiftUI

struct AttachmentCardView: View {
    let result: AttachmentSearchResult
    let isSearchActive: Bool
    @Environment(\.theme) private var theme

    // MARK: - Computed

    private var fileTypeIcon: String {
        Attachment.FileType(rawValue: result.attachment.fileType)?.rawValue ?? "doc.fill"
    }

    private var fileTypeLabel: String {
        Attachment.FileType(rawValue: result.attachment.fileType)?.label ?? "File"
    }

    private var formattedDate: String {
        guard let date = result.attachment.emailDate else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    private var scoreColor: Color {
        if result.score > 0.7 { return .green }
        if result.score > 0.4 { return .orange }
        return .red
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 10) {
            // File type icon in a rounded rectangle
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.cardBackground)
                    .frame(height: 80)
                Image(systemName: fileTypeIcon)
                    .font(.system(size: 28))
                    .foregroundStyle(theme.accentPrimary)
            }

            // Filename (2 lines max, centered)
            Text(result.attachment.filename)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // Sender + date
            VStack(spacing: 2) {
                if let sender = result.attachment.senderName ?? result.attachment.senderEmail {
                    Text(sender)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Text(formattedDate)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textTertiary)
            }

            // Relevance score (only during search)
            if isSearchActive {
                HStack(spacing: 4) {
                    Circle()
                        .fill(scoreColor)
                        .frame(width: 6, height: 6)
                    Text("\(Int(result.score * 100))%")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.detailBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.divider, lineWidth: 1))
    }
}
