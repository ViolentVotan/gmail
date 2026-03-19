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
            HStack(spacing: Spacing.xs) {
                if showArchive {
                    Button {
                        actionTrigger.toggle()
                        actions.onArchive?(email)
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .help("Archive")
                }

                if showDelete {
                    Button {
                        actionTrigger.toggle()
                        actions.onDelete?(email)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .tint(SemanticColor.error)
                    .help("Move to Trash")
                }

                if showSnooze {
                    Button {
                        actionTrigger.toggle()
                        actions.onSnooze?(email, SnoozePreset.tomorrowMorning)
                    } label: {
                        Image(systemName: "clock")
                    }
                    .help("Snooze until tomorrow 8:00 AM")
                }

                if showReadUnread {
                    if email.isRead {
                        Button {
                            actionTrigger.toggle()
                            actions.onMarkUnread?(email)
                        } label: {
                            Image(systemName: "envelope.badge")
                        }
                        .help("Mark as Unread")
                    } else {
                        Button {
                            actionTrigger.toggle()
                            actions.onMarkRead?(email)
                        } label: {
                            Image(systemName: "envelope.open")
                        }
                        .help("Mark as Read")
                    }
                }
            }
            .buttonStyle(.glass)
            .font(Typography.captionRegular)
            .frame(height: ButtonSize.sm)
            .symbolEffect(.bounce, value: actionTrigger)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: actionTrigger)
            .padding(.trailing, Spacing.xl)
            .padding(.leading, Spacing.xxl)
            .background {
                LinearGradient(
                    colors: [.clear, .clear, Color(nsColor: .controlBackgroundColor).opacity(0.9)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .opacity(isHovered ? 1 : 0)
            .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: isHovered)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(true)
        }
    }
}
