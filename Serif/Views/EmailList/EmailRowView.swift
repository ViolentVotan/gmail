import SwiftUI

struct EmailRowView: View {
    let email: Email
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var popoverHolder = PopoverHolder()

    private var nudgeText: String? {
        let daysAgo = Calendar.current.dateComponents([.day], from: email.date, to: Date()).day ?? 0
        guard daysAgo >= 3 else { return nil }
        return "Received \(daysAgo) days ago"
    }

    private func tagColor(_ name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "red": return .red
        case "green": return .green
        default: return .secondary
        }
    }

    private static let isAppleIntelligenceAvailable: Bool = {
        guard #available(macOS 26.0, *) else { return false }
        #if canImport(FoundationModels)
        return true
        #else
        return false
        #endif
    }()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Unread indicator
                Circle()
                    .fill(email.isRead ? Color.clear : Color.blue)
                    .frame(width: 6, height: 6)

                // Avatar
                AvatarView(
                    initials: email.sender.initials,
                    color: email.sender.avatarColor,
                    size: 36,
                    avatarURL: email.sender.avatarURL,
                    senderDomain: email.sender.domain
                )

                // Content
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(email.isDraft && email.recipients.isEmpty ? "Draft" : email.sender.name)
                            .font(.body.weight(email.isRead ? .medium : .semibold))
                            .foregroundStyle(email.isDraft && email.recipients.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                            .lineLimit(1)

                        if email.threadMessageCount > 1 {
                            Text("\(email.threadMessageCount)")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Circle().fill(Color.accentColor.opacity(0.75)))
                        }

                        Spacer()

                        Text(email.date.formattedRelative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Text(email.subject)
                        .font(.subheadline.weight(email.isRead ? .regular : .medium))
                        .foregroundStyle(email.isRead ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)

                    Text(email.preview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    if let nudge = nudgeText {
                        Text(nudge)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if !email.labels.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(email.labels.prefix(3)) { label in
                                LabelChipView(label: label)
                            }
                            if email.labels.count > 3 {
                                Text("+\(email.labels.count - 3)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.fill.quaternary))
                            }
                        }
                        .padding(.top, 2)
                    }

                    if let tags = EmailClassifier.shared.cachedTags(for: email.gmailMessageID ?? "") {
                        HStack(spacing: 4) {
                            ForEach(tags.activeTags, id: \.label) { tag in
                                Text(tag.label)
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(tagColor(tag.color).opacity(0.15))
                                    .foregroundStyle(tagColor(tag.color))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    }
                }

                // Indicators
                VStack(spacing: 4) {
                    if email.isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                    if email.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.1)) : (isHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(Color.clear)))
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(PopoverAnchor(holder: popoverHolder))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(email.sender.name), \(email.subject), \(email.preview)")
        .accessibilityValue(email.isRead ? "Read" : "Unread")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Double-tap to read")
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                guard !popoverHolder.isShowing, Self.isAppleIntelligenceAvailable else { return }
                hoverTask?.cancel()
                hoverTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    let content = EmailHoverSummaryView(email: email)
                        .frame(width: 340)
                    popoverHolder.show(content: content)
                }
            } else {
                hoverTask?.cancel()
                hoverTask = nil
                popoverHolder.close()
            }
        }
        .onChange(of: isSelected) { _, _ in
            hoverTask?.cancel()
            popoverHolder.close()
        }
        .onDisappear {
            hoverTask?.cancel()
            popoverHolder.close()
        }
    }
}

// MARK: - NSPopover wrapper

@MainActor
private class PopoverHolder {
    private var popover: NSPopover?
    weak var anchorView: NSView?

    var isShowing: Bool { popover?.isShown == true }

    func show<V: View>(content: V) {
        guard let anchorView, !isShowing else { return }
        let controller = NSHostingController(rootView: content)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxX)
        self.popover = popover
    }

    func close() {
        popover?.performClose(nil)
        popover = nil
    }
}

private struct PopoverAnchor: NSViewRepresentable {
    let holder: PopoverHolder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.anchorView = nsView
    }
}
