import SwiftUI

struct EmailRowView: View, Equatable {
    let email: Email
    let isSelected: Bool
    let accountID: String
    let selectedFolder: Folder
    var isMultiSelect = false
    let action: () -> Void
    var entranceIndex: Int = 0
    var hasAlreadyAnimated: Bool = false
    var onFirstAppear: (() -> Void)?
    @State private var isHovered = false
    @State private var isPressed = false
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let density: EmailDensity
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
    /// Cached at init to avoid Calendar.current per-render overhead.
    private let formattedDate: String
    private let nudgeText: String?

    /// Equatable conformance compares only the data that affects visual output.
    /// Closures are excluded — they capture the same email context when equal.
    static func == (lhs: EmailRowView, rhs: EmailRowView) -> Bool {
        lhs.email == rhs.email
            && lhs.isSelected == rhs.isSelected
            && lhs.accountID == rhs.accountID
            && lhs.selectedFolder == rhs.selectedFolder
            && lhs.isMultiSelect == rhs.isMultiSelect
            && lhs.density == rhs.density
            && lhs.hasAlreadyAnimated == rhs.hasAlreadyAnimated
    }

    init(
        email: Email,
        isSelected: Bool,
        accountID: String,
        selectedFolder: Folder,
        isMultiSelect: Bool = false,
        density: EmailDensity = .comfortable,
        action: @escaping () -> Void,
        entranceIndex: Int = 0,
        hasAlreadyAnimated: Bool = false,
        onFirstAppear: (() -> Void)? = nil
    ) {
        self.email = email
        self.isSelected = isSelected
        self.accountID = accountID
        self.selectedFolder = selectedFolder
        self.isMultiSelect = isMultiSelect
        self.density = density
        self.action = action
        self.entranceIndex = entranceIndex
        self.hasAlreadyAnimated = hasAlreadyAnimated
        self.onFirstAppear = onFirstAppear

        self.labelBadges = email.labels.map { .label($0) }

        if let tags = email.tags {
            self.tagBadges = tags.activeTags.map { .tag(label: $0.label, color: $0.color) }
        } else {
            self.tagBadges = []
        }

        self.formattedDate = email.date.formattedRelative

        let daysAgo = Calendar.current.dateComponents([.day], from: email.date, to: .now).day ?? 0
        self.nudgeText = daysAgo >= 3 ? "Received \(daysAgo) days ago" : nil
    }

    @ViewBuilder
    private var threadCountBadge: some View {
        let highlighted = isHovered || isSelected
        Text("\(email.threadMessageCount)")
            .font(Typography.captionSmall)
            .foregroundStyle(highlighted ? .primary : .secondary)
            .contentTransition(.numericText())
            .frame(minWidth: threadBadgeSize, minHeight: threadBadgeSize)
            .background {
                if highlighted {
                    Capsule().fill(.fill.secondary)
                } else {
                    Capsule().fill(.fill.quaternary)
                }
            }
    }

    private func tagColor(_ name: String) -> Color {
        switch name {
        case "blue": return BrandColor.blueText
        case "red": return SemanticColor.error
        case "green": return SemanticColor.success
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
        case .compact:   return 6
        case .spacious:  return 14
        case .comfortable: return 10
        }
    }

    private var showPreview: Bool {
        density != .compact
    }

    @ViewBuilder
    private func badgeView(_ badge: BadgeItem) -> some View {
        switch badge {
        case .label(let label):
            LabelChipView(label: label)
        case .tag(let label, let color):
            Text(label)
                .font(Typography.microTag)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxxs)
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
            HStack(spacing: Spacing.md) {
                // Unread indicator: filled accent dot + bold sender text provide dual visual cues
                Circle()
                    .fill(email.isRead ? Color.clear : Color.accentColor)
                    .overlay(email.isRead ? Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1) : nil)
                    .frame(width: dotSize, height: dotSize)
                    .animation(reduceMotion ? nil : VikAnimation.microBounce, value: email.isRead)

                // Avatar
                AvatarView(
                    initials: email.sender.initials,
                    color: email.sender.avatarColor,
                    size: avatarSize,
                    avatarURL: email.sender.avatarURL,
                    senderDomain: email.sender.domain
                )

                // Content
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text(email.isDraft && email.recipients.isEmpty ? "Draft" : email.sender.name)
                            .font(email.isRead ? Typography.callout : Typography.calloutSemibold)
                            .foregroundStyle(email.isDraft && email.recipients.isEmpty ? .tertiary : .primary)
                            .lineLimit(1)

                        if email.threadMessageCount > 1 {
                            threadCountBadge
                        }

                        Spacer()

                        Text(formattedDate)
                            .font(Typography.captionRegular)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }

                    Text(email.subject)
                        .font(Typography.callout)
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
                            .lineLimit(1)
                    }

                    if !labelBadges.isEmpty || (showTags && !tagBadges.isEmpty) {
                        let visibleLabelCount = showTags ? 2 : 1
                        HStack(spacing: Spacing.xs) {
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
                                    .padding(.horizontal, Spacing.xs)
                                    .padding(.vertical, Spacing.xxs)
                                    .background(Capsule().fill(.fill.quaternary))
                            }
                        }
                        .animation(reduceMotion ? nil : VikAnimation.springSnappy, value: showTags)
                    }
                }

                // Indicators
                VStack(spacing: Spacing.xs) {
                    if email.isStarred {
                        Image(systemName: "star.fill")
                            .font(Typography.captionSmallRegular)
                            .foregroundStyle(.tint)
                            .transition(.scale.combined(with: .opacity))
                            .symbolEffect(.bounce, value: email.isStarred)
                    }
                    if email.hasAttachments {
                        HStack(spacing: 2) {
                            Image(systemName: "paperclip")
                            if email.attachmentCount > 1 {
                                Text("\(email.attachmentCount)")
                            }
                        }
                        .font(Typography.captionSmallRegular)
                        .foregroundStyle(.tertiary)
                    }
                }
                .sensoryFeedback(.impact(flexibility: .soft), trigger: email.isStarred)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, verticalPadding)
            .background {
                if !email.isRead && !isSelected {
                    RoundedRectangle(cornerRadius: CornerRadius.sm)
                        .fill(.tint.opacity(OpacityToken.tint))
                }
            }
            .padding(.horizontal, Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressTrackingButtonStyle(isPressed: $isPressed))
        .overlay(alignment: .topTrailing) {
            if !isMultiSelect {
                HoverActionButtonsView(
                    email: email,
                    isHovered: isHovered,
                    isSelected: isSelected,
                    selectedFolder: selectedFolder
                )
                .padding(.top, verticalPadding)
            }
        }
        .glassEffect(
            isSelected ? .regular.interactive() : .identity,
            in: .rect(cornerRadius: CornerRadius.sm)
        )
        .background(
            Color.primary.opacity(isHovered && !isSelected ? OpacityToken.hoverFill : 0),
            in: .rect(cornerRadius: CornerRadius.sm)
        )
        .sensoryFeedback(.selection, trigger: isSelected)
        .scaleEffect(isPressed ? ScaleToken.press : (isHovered && !isSelected ? ScaleToken.rowHover : 1.0), anchor: .center)
        .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: isHovered || isSelected)
        .draggable(EmailDragItem(
            messageIds: [email.gmailMessageID ?? ""],
            accountID: accountID
        ))
        .opacity(hasAppeared || hasAlreadyAnimated ? 1 : 0)
        .offset(y: hasAppeared || hasAlreadyAnimated ? 0 : OffsetToken.small)
        .onAppear {
            guard !hasAppeared, !hasAlreadyAnimated else { return }
            if reduceMotion {
                hasAppeared = true
                onFirstAppear?()
            } else {
                let delay = Double(min(entranceIndex, 8)) * DurationToken.stagger
                withAnimation(VikAnimation.springDefault.delay(delay)) {
                    hasAppeared = true
                }
                onFirstAppear?()
            }
        }
        .background {
            if Self.isAppleIntelligenceAvailable {
                PopoverAnchor(holder: popoverHolder)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(email.sender.name), \(email.subject), \(email.preview), \(formattedDate)")
        .accessibilityHint("Opens email thread")
        .accessibilityValue("\(email.isRead ? "Read" : "Unread"), \(email.isStarred ? "Starred" : "Not starred")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                guard Self.isAppleIntelligenceAvailable else { return }
                hoverTask?.cancel()
                hoverTask = Task { [popoverHolder] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, !popoverHolder.isShowing else { return }
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
            tagRevealTask?.cancel()
            tagRevealTask = nil
            hoverTask?.cancel()
            hoverTask = nil
            popoverHolder.close()
        }
    }
}



// MARK: - NSPopover wrapper

@MainActor
private final class PopoverHolder: NSObject, NSPopoverDelegate {
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
        popover.delegate = self
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxX)
        self.popover = popover
    }

    func close() {
        popover?.close()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            popover = nil
        }
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
