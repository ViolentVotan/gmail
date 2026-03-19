import SwiftUI

// MARK: - CalendarEventCard

struct CalendarEventCard: View {
    let event: CalendarEvent
    let height: CGFloat
    let onSelect: (CalendarEvent) -> Void

    @State private var isHovered = false
    @GestureState private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            // Left colored border
            Rectangle()
                .fill(event.resolvedColor)
                .frame(width: CalendarLayout.eventCardBorderWidth)

            // Content
            VStack(alignment: .leading, spacing: 1) {
                Text(event.summary)
                    .font(Typography.calendarEventTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(height > 36 ? 2 : 1)

                if height > 28 {
                    Text(timeRangeText)
                        .font(Typography.calendarEventTime)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: max(height, CalendarLayout.eventCardMinHeight))
        .background(
            event.resolvedColor.opacity(CalendarSemanticColor.eventCardBackgroundOpacity),
            in: .rect(cornerRadius: CornerRadius.sm)
        )
        .glassEffect(
            isHovered ? .regular.interactive() : .identity,
            in: .rect(cornerRadius: CornerRadius.sm)
        )
        .scaleEffect(reduceMotion ? 1.0 : (isPressed ? ScaleToken.press : (isHovered ? ScaleToken.rowHover : 1.0)))
        .shadow(
            color: isHovered ? event.resolvedColor.opacity(0.2) : .clear,
            radius: isHovered ? 4 : 0,
            y: isHovered ? 2 : 0
        )
        .animation(reduceMotion ? nil : VikAnimation.springSnappy, value: isPressed)
        .animation(reduceMotion ? nil : VikAnimation.springDefault, value: isHovered)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
                .onEnded { _ in onSelect(event) }
        )
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(event.summary), \(timeRangeText)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Private

    private var timeRangeText: String {
        if event.isAllDay {
            return "All day"
        }
        return "\(event.startTime.formattedTime) – \(event.endTime.formattedTime)"
    }
}

// MARK: - Preview

#Preview {
    let event = CalendarEvent(
        id: "test_primary_1",
        googleEventId: "1",
        calendarId: "primary",
        accountID: "test",
        summary: "Team Standup",
        description: nil,
        location: nil,
        startTime: Date(),
        endTime: Date().addingTimeInterval(3600),
        isAllDay: false,
        timeZone: nil,
        status: .confirmed,
        organizer: nil,
        creator: nil,
        attendees: [],
        selfResponseStatus: .accepted,
        conferenceLink: nil,
        conferenceName: nil,
        colorId: nil,
        resolvedColor: BrandColor.blue,
        isRecurring: false,
        recurringEventId: nil,
        reminders: [],
        eventType: .default,
        etag: "",
        htmlLink: nil,
        canEdit: true,
        attachments: []
    )
    CalendarEventCard(event: event, height: 48) { _ in }
        .frame(width: 200)
        .padding()
}
