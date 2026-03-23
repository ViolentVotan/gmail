import SwiftUI

struct CalendarContextCard: View {
    let event: CalendarEvent
    var onNavigate: () -> Void
    var onDismiss: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onNavigate) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(Typography.subheadSemibold)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contextLabel)
                        .font(Typography.captionRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(event.summary)
                        .font(Typography.subhead)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(Typography.captionSmall)
                        .foregroundStyle(.tertiary)
                        .frame(width: ButtonSize.sm, height: ButtonSize.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(.regularMaterial, in: .rect(cornerRadius: CornerRadius.md))
            .contentShape(.rect(cornerRadius: CornerRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(contextLabel + " — " + event.summary)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Open in Calendar")
        .onHover { isHovered = $0 }
        .scaleEffect(reduceMotion ? 1.0 : (isHovered ? ScaleToken.rowHover : 1.0))
        .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: isHovered)
    }

    // MARK: - Helpers

    private var participantName: String {
        event.organizer?.displayName ?? event.organizer?.email
            ?? event.attendees.first(where: { !$0.isOrganizer })?.displayName
            ?? event.attendees.first?.email
            ?? ""
    }

    private var contextLabel: String {
        let name = participantName
        let relative = event.startTime.relativeFormatted
        if name.isEmpty {
            return "You have a meeting \(relative)"
        }
        return "You have a meeting with \(name) \(relative)"
    }
}

// MARK: - Date Relative Formatting

private extension Date {
    /// Returns a relative time string like "in 3 hours", "tomorrow", "in 2 days".
    var relativeFormatted: String {
        formatted(.relative(presentation: .named))
    }
}
