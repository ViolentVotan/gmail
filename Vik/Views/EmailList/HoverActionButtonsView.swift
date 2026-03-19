import SwiftUI

// MARK: - Environment

/// Lightweight action container — only the actions hover buttons need (ISP).
/// `@MainActor` matches `EmailListActions` isolation.
@MainActor
struct EmailHoverActions {
    var onArchive: ((Email) -> Void)?
    var onDelete: ((Email) -> Void)?
    var onSnooze: ((Email, Date) -> Void)?
    var onMarkRead: ((Email) -> Void)?
    var onMarkUnread: ((Email) -> Void)?
}

@MainActor
struct EmailHoverActionsKey: EnvironmentKey {
    static let defaultValue = EmailHoverActions()
}

extension EnvironmentValues {
    @MainActor var emailHoverActions: EmailHoverActions {
        get { self[EmailHoverActionsKey.self] }
        set { self[EmailHoverActionsKey.self] = newValue }
    }
}

// MARK: - View

struct HoverActionButtonsView: View {
    let email: Email
    let isHovered: Bool
    let selectedFolder: Folder
    @Environment(\.emailHoverActions) private var actions
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
            .glassEffect(.regular, in: .capsule)
            .symbolEffect(.bounce, value: actionTrigger)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: actionTrigger)
            .padding(.trailing, Spacing.lg)
            .opacity(isHovered ? 1 : 0)
            .scaleEffect(isHovered ? 1 : 0.9, anchor: .trailing)
            .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: isHovered)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func hoverButton(
        _ icon: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role) {
            actionTrigger.toggle()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
