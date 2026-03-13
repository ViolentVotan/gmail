import SwiftUI

struct BulkActionBarView: View {
    let count: Int
    let selectedFolder: Folder
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onMarkUnread: () -> Void
    let onMarkRead: () -> Void
    let onToggleStar: () -> Void
    let onMoveToInbox: () -> Void
    let onDeselectAll: () -> Void

    @ScaledMetric(relativeTo: .title3) private var tileWidth: CGFloat = 64
    @ScaledMetric(relativeTo: .title3) private var tileHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)

            Text("\(count) emails selected")
                .font(Typography.title)
                .foregroundStyle(.primary)

            HStack(spacing: Spacing.md) {
                if selectedFolder != .archive {
                    actionButton(icon: "archivebox", label: "Archive", action: onArchive)
                }
                if selectedFolder != .trash {
                    actionButton(icon: "trash", label: "Delete", action: onDelete, destructive: true)
                }
                actionButton(icon: "envelope.badge", label: "Unread", action: onMarkUnread)
                actionButton(icon: "envelope.open", label: "Read", action: onMarkRead)
                actionButton(icon: "star", label: "Star", action: onToggleStar)
                if selectedFolder == .archive || selectedFolder == .trash {
                    actionButton(icon: "tray.and.arrow.down", label: "Inbox", action: onMoveToInbox)
                }
            }

            Button {
                onDeselectAll()
            } label: {
                Text("Deselect All")
                    .font(Typography.subhead)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.sm))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Deselect All")

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(Typography.caption)
            }
            .foregroundStyle(destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .frame(width: tileWidth, height: tileHeight)
            .glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
