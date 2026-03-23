import SwiftUI

struct BulkActionBarView: View {
    let count: Int
    let selectedFolder: Folder
    let emails: [Email]
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onMarkUnread: () -> Void
    let onMarkRead: () -> Void
    let onToggleStar: () -> Void
    let onMoveToInbox: () -> Void
    let onDeselectAll: () -> Void

    private var allStarred: Bool {
        !emails.isEmpty && emails.allSatisfy(\.isStarred)
    }

    @ScaledMetric(relativeTo: .title3) private var tileWidth: CGFloat = 64
    @ScaledMetric(relativeTo: .title3) private var tileHeight: CGFloat = 56

    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(Typography.emptyStateMediumIcon)
                .foregroundStyle(.tint)

            Text("\(count) emails selected")
                .font(Typography.title)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            GlassEffectContainer {
                actionRow
            }

            Button {
                onDeselectAll()
            } label: {
                Text("Deselect All")
                    .font(Typography.subhead)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .contentShape(.rect)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: CornerRadius.sm))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Deselect All")
            .help("Deselect All")

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionRow: some View {
        HStack(spacing: Spacing.md) {
            if selectedFolder != .archive {
                actionButton(icon: "archivebox", label: "Archive", action: onArchive)
            }
            if selectedFolder != .trash {
                actionButton(icon: "trash", label: "Delete", action: { showDeleteConfirmation = true }, destructive: true)
                    .alert("Delete \(count) email\(count == 1 ? "" : "s")?", isPresented: $showDeleteConfirmation) {
                        Button("Delete", role: .destructive) { onDelete() }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This will move the selected emails to Trash.")
                    }
            }
            actionButton(icon: "envelope.badge", label: "Unread", action: onMarkUnread)
            actionButton(icon: "envelope.open", label: "Read", action: onMarkRead)
            actionButton(icon: allStarred ? "star.fill" : "star", label: allStarred ? "Unstar" : "Star", action: onToggleStar)
            if selectedFolder == .archive || selectedFolder == .trash {
                actionButton(icon: "tray.and.arrow.down", label: "Inbox", action: onMoveToInbox)
            }
        }
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(Typography.title)
                Text(label)
                    .font(Typography.caption)
            }
            .foregroundStyle(destructive ? SemanticColor.error : .secondary)
            .frame(width: tileWidth, height: tileHeight)
            .contentShape(.rect)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: CornerRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
