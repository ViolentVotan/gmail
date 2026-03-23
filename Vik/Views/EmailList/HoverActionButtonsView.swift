import SwiftUI

// MARK: - Environment

/// Lightweight action container — only the actions hover buttons need (ISP).
/// Stored as `@State` in `EmailListView` so the environment reference stays stable
/// across renders; only the closure properties are updated, not the injected object.
@Observable @MainActor
final class EmailHoverActions {
    var onArchive: ((Email) -> Void)?
    var onDelete: ((Email) -> Void)?
    var onSnooze: ((Email, Date) -> Void)?
    var onMarkRead: ((Email) -> Void)?
    var onMarkUnread: ((Email) -> Void)?
}

// MARK: - View

struct HoverActionButtonsView: View {
    let email: Email
    let isHovered: Bool
    let selectedFolder: Folder
    @Environment(EmailHoverActions.self) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actionTrigger = false

    /// Drafts and certain folders suppress all hover actions.
    private var hasVisibleButtons: Bool {
        !email.isDraft && selectedFolder != .drafts && selectedFolder != .scheduled
    }

    private var showArchive: Bool {
        ![.archive, .trash, .sent, .drafts, .spam, .scheduled].contains(selectedFolder)
    }

    private var showDelete: Bool {
        selectedFolder != .trash
    }

    private var showSnooze: Bool {
        ![.snoozed, .trash, .sent, .drafts, .spam, .scheduled].contains(selectedFolder)
    }

    private var showReadUnread: Bool {
        ![.sent, .drafts, .scheduled].contains(selectedFolder)
    }

    var body: some View {
        if hasVisibleButtons {
            HStack(spacing: 2) {
                if showArchive {
                    hoverButton("archivebox", help: "Archive") {
                        actions.onArchive?(email)
                    }
                }

                if showDelete {
                    hoverButton("trash", help: "Move to Trash", role: .destructive) {
                        actions.onDelete?(email)
                    }
                }

                if showSnooze {
                    hoverButton("clock", help: "Snooze until tomorrow 8:00 AM") {
                        actions.onSnooze?(email, SnoozePreset.tomorrowMorning)
                    }
                }

                if showReadUnread {
                    if email.isRead {
                        hoverButton("envelope.badge", help: "Mark as Unread") {
                            actions.onMarkUnread?(email)
                        }
                    } else {
                        hoverButton("envelope.open", help: "Mark as Read") {
                            actions.onMarkRead?(email)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .glassEffect(.regular.interactive(), in: .capsule)
            .symbolEffect(.bounce, value: actionTrigger)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: actionTrigger)
            .padding(.trailing, Spacing.lg)
            .opacity(isHovered ? 1 : 0)
            .scaleEffect(isHovered ? 1 : 0.9, anchor: .trailing)
            .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: isHovered)
            .allowsHitTesting(isHovered)
        }
    }

    @ViewBuilder
    private func hoverButton(
        _ icon: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HoverActionButton(
            icon: icon,
            help: help,
            role: role,
            actionTrigger: $actionTrigger,
            action: action
        )
    }
}

// MARK: - Single Hover Button

/// Extracted so each button owns its own `@State` hover tracking.
private struct HoverActionButton: View {
    let icon: String
    let help: String
    var role: ButtonRole?
    @Binding var actionTrigger: Bool
    let action: () -> Void

    @State private var isButtonHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(role: role) {
            actionTrigger.toggle()
            action()
        } label: {
            Image(systemName: icon)
                .font(Typography.captionSmallMedium)
                .frame(width: 32, height: 32)
                .contentShape(.rect.inset(by: -6))
        }
        .buttonStyle(.borderless)
        .background(
            .primary.opacity(isButtonHovered ? OpacityToken.highlight : 0),
            in: .rect(cornerRadius: CornerRadius.xs)
        )
        .scaleEffect(isButtonHovered ? ScaleToken.hover : 1)
        .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: isButtonHovered)
        .onHover { isButtonHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
