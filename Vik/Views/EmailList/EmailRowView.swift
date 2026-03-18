import SwiftUI

struct EmailRowView: View, Equatable {
    let email: Email
    let isSelected: Bool
    let accountID: String
    let action: () -> Void
    var entranceIndex: Int = 0
    @State private var isHovered = false
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("emailDensity") private var density = "comfortable"
    @State private var showTags = false
    @State private var tagRevealTask: Task<Void, Never>?
    @State private var hoverTask: Task<Void, Never>?
    @State private var popoverHolder = PopoverHolder()
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 30
    @ScaledMetric(relativeTo: .caption2) private var dotSize: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var threadBadgeSize: CGFloat = 18

    /// Cached at init to avoid per-render allocations.
    private let labelBadges: [BadgeItem]
    /// Cached at init to avoid per-render allocations and direct service access.
    private let tagBadges: [BadgeItem]
    /// Cached at init to avoid Calendar arithmetic on every body evaluation.
    private let nudgeText: String?

    /// Equatable conformance compares only the data that affects visual output.
    /// Closures are excluded — they capture the same email context when equal.
    static func == (lhs: EmailRowView, rhs: EmailRowView) -> Bool {
        lhs.email == rhs.email && lhs.isSelected == rhs.isSelected && lhs.accountID == rhs.accountID
    }

    init(email: Email, isSelected: Bool, accountID: String, action: @escaping () -> Void, entranceIndex: Int = 0) {
        self.email = email
        self.isSelected = isSelected
        self.accountID = accountID
        self.action = action
        self.entranceIndex = entranceIndex

        self.labelBadges = email.labels.map { .label($0) }

        if let tags = email.tags {
            self.tagBadges = tags.activeTags.map { .tag(label: $0.label, color: $0.color) }
        } else {
            self.tagBadges = []
        }

        let daysAgo = Calendar.current.dateComponents([.day], from: email.date, to: .now).day ?? 0
        self.nudgeText = daysAgo >= 3 ? "Received \(daysAgo) days ago" : nil
    }

    private func tagColor(_ name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "red": return .red
        case "green": return .green
        case "gray": return .secondary
        default: return .secondary
        }
    }

    private enum BadgeItem: Identifiable {
        case label(EmailLabel)
        case tag(label: String, color: String)

        var id: String {
            switch self {
            case .label(let l): return "l-\(l.id)"
            case .tag(let label, _): return "t-\(label)"
            }
        }
    }

    private var verticalPadding: CGFloat {
        switch density {
        case "compact":  return 6
        case "spacious": return 14
        default:         return 10
        }
    }

    private var showPreview: Bool {
        density != "compact"
    }

    @ViewBuilder
    private func badgeView(_ badge: BadgeItem) -> some View {
        switch badge {
        case .label(let label):
            LabelChipView(label: label)
        case .tag(let label, let color):
            Text(label)
                .font(Typography.microTag)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(tagColor(color).opacity(OpacityToken.highlight), in: .capsule)
                .foregroundStyle(tagColor(color))
                .glassEffect(.regular, in: .capsule)
        }
    }

    private static let isAppleIntelligenceAvailable: Bool = {
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
                    .fill(email.isRead ? Color.clear : Color.accentColor)
                    .frame(width: dotSize, height: dotSize)
                    .animation(VikAnimation.microBounce, value: email.isRead)

                // Avatar
                AvatarView(
                    initials: email.sender.initials,
                    color: email.sender.avatarColor,
                    size: avatarSize,
                    avatarURL: email.sender.avatarURL,
                    senderDomain: email.sender.domain
                )

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(email.isDraft && email.recipients.isEmpty ? "Draft" : email.sender.name)
                            .font(.callout.weight(email.isRead ? .regular : .semibold))
                            .foregroundStyle(email.isDraft && email.recipients.isEmpty ? .tertiary : .primary)
                            .lineLimit(1)

                        if email.threadMessageCount > 1 {
                            Text("\(email.threadMessageCount)")
                                .font(Typography.captionSmall)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                                .frame(minWidth: threadBadgeSize, minHeight: threadBadgeSize)
                                .background(Capsule().fill(.fill.quaternary))
                        }

                        Spacer()

                        Text(email.date.formattedRelative)
                            .font(Typography.captionRegular)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }

                    Text(email.subject)
                        .font(Typography.subheadRegular)
                        .foregroundStyle(email.isRead ? .secondary : .primary)
                        .lineLimit(1)

                    if showPreview {
                        Text(email.preview)
                            .font(Typography.captionRegular)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    if showPreview, let nudge = nudgeText {
                        Text(nudge)
                            .font(Typography.captionSmallRegular)
                            .foregroundStyle(SemanticColor.warning)
                    }

                    if !labelBadges.isEmpty || (showTags && !tagBadges.isEmpty) {
                        let visibleLabelCount = showTags ? 2 : 1
                        HStack(spacing: 4) {
                            ForEach(labelBadges.prefix(visibleLabelCount)) { badge in
                                badgeView(badge)
                            }
                            if showTags {
                                ForEach(tagBadges.prefix(2)) { badge in
                                    badgeView(badge)
                                }
                            }
                            let totalVisible = labelBadges.prefix(visibleLabelCount).count + (showTags ? tagBadges.prefix(2).count : 0)
                            let totalCount = labelBadges.count + tagBadges.count
                            if totalCount > totalVisible {
                                Text("+\(totalCount - totalVisible)")
                                    .font(Typography.captionSmallMedium)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.fill.quaternary))
                            }
                        }
                        .animation(VikAnimation.springSnappy, value: showTags)
                    }
                }

                // Indicators
                VStack(spacing: 4) {
                    if email.isStarred {
                        Image(systemName: "star.fill")
                            .font(Typography.captionSmallRegular)
                            .foregroundStyle(.tint)
                            .transition(.scale.combined(with: .opacity))
                            .symbolEffect(.bounce, value: email.isStarred)
                    }
                    if email.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(Typography.captionSmallRegular)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, verticalPadding)
            .background {
                if !email.isRead && !isSelected {
                    RoundedRectangle(cornerRadius: CornerRadius.sm)
                        .fill(.tint.opacity(0.03))
                }
            }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected || isHovered ? .regular.interactive() : .identity,
            in: .rect(cornerRadius: CornerRadius.sm)
        )
        .scaleEffect(isHovered && !isSelected ? ScaleToken.rowHover : 1.0, anchor: .center)
        .animation(.snappy(duration: 0.2), value: isHovered)
        .animation(.snappy(duration: 0.2), value: isSelected)
        .draggable(EmailDragItem(
            messageIds: [email.gmailMessageID ?? ""],
            accountID: accountID
        ))
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : OffsetToken.small)
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                let delay = Double(min(entranceIndex, 8)) * DurationToken.stagger
                withAnimation(VikAnimation.springDefault.delay(delay)) {
                    hasAppeared = true
                }
            }
        }
        .background(PopoverAnchor(holder: popoverHolder))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(email.sender.name), \(email.subject), \(email.preview), \(email.date.formatted())")
        .accessibilityValue(email.isRead ? "Read" : "Unread")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(email.isStarred ? "Starred" : "Not starred")
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                // Reveal AI tags after a short delay
                tagRevealTask?.cancel()
                tagRevealTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    showTags = true
                }

                // Apple Intelligence hover summary
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
                tagRevealTask?.cancel()
                tagRevealTask = nil
                showTags = false

                hoverTask?.cancel()
                hoverTask = nil
                popoverHolder.close()
            }
        }
        .onChange(of: email.id) {
            tagRevealTask?.cancel()
            showTags = false
            hoverTask?.cancel()
            popoverHolder.close()
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
