import SwiftUI

// MARK: - Inbox Parent Row

struct InboxParentRow: View {
    let isSelected: Bool
    let isExpanded: Bool
    @Binding var inboxExpanded: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            if isExpanded {
                HStack(spacing: 10) {
                    Image(systemName: "tray.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : (isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                        .frame(width: 20)

                    Text("Inbox")
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : (isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()

                    // Chevron to expand/collapse subcategories
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { inboxExpanded.toggle() }
                    } label: {
                        Image(systemName: inboxExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : (isHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(Color.clear)))
                )
                .contentShape(Rectangle())
            } else {
                // Collapsed: just the icon with dot if needed
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.15))
                    }
                    Image(systemName: "tray.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : (isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                }
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isExpanded ? "" : "Inbox")
    }
}

// MARK: - Inbox Category Row

struct InboxCategoryRow: View {
    let category: InboxCategory
    let isSelected: Bool
    let unreadCount: Int
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Indent marker
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 16)

                Image(systemName: category.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : (isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                    .frame(width: 16)

                Text(category.displayName)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : (isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))

                Spacer()

                if unreadCount > 0 {
                    BadgeView(count: unreadCount, isSelected: isSelected)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : (isHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(Color.clear)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Labels Parent Row

struct LabelsParentRow: View {
    let isSelected: Bool
    let isExpanded: Bool
    @Binding var labelsExpanded: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            if isExpanded {
                HStack(spacing: 10) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : (isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                        .frame(width: 20)

                    Text("Labels")
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : (isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { labelsExpanded.toggle() }
                    } label: {
                        Image(systemName: labelsExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : (isHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(Color.clear)))
                )
                .contentShape(Rectangle())
            } else {
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.15))
                    }
                    Image(systemName: "tag.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : (isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                }
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isExpanded ? "" : "Labels")
    }
}

// MARK: - Label Sidebar Row

struct LabelSidebarRow: View {
    let label: GmailLabel
    let isSelected: Bool
    var onRename: ((GmailLabel) -> Void)?
    var onDelete: ((GmailLabel) -> Void)?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 16)

                Circle()
                    .fill(Color(hex: label.resolvedTextColor))
                    .frame(width: 8, height: 8)

                Text(label.displayName)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : (isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()

                if let unread = label.messagesUnread, unread > 0 {
                    BadgeView(count: unread, isSelected: isSelected)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : (isHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(Color.clear)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Rename...") { onRename?(label) }
            Divider()
            Button("Delete", role: .destructive) { onDelete?(label) }
        }
    }
}

// MARK: - Generic Folder Item

struct SidebarItemView: View {
    let folder: Folder
    let isSelected: Bool
    let isExpanded: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            if isExpanded { expandedContent } else { collapsedContent }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isExpanded ? "" : folder.rawValue)
    }

    private var expandedContent: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.icon)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : (isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                .frame(width: 20)

            Text(folder.rawValue)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : (isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                .fixedSize(horizontal: true, vertical: false)
            Spacer()

            if folder.count > 0 {
                Text("\(folder.count)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.fill.quaternary))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : (isHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(Color.clear)))
        )
        .contentShape(Rectangle())
    }

    private var collapsedContent: some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.15))
            }
            ZStack(alignment: .topTrailing) {
                Image(systemName: folder.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : (isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                if folder.count > 0 {
                    Circle().fill(.tint).frame(width: 8, height: 8).offset(x: 4, y: -2)
                }
            }
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
}
