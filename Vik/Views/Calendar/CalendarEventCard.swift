import SwiftUI

// MARK: - CalendarEventCard

struct CalendarEventCard: View {
    let event: CalendarEvent
    let height: CGFloat
    let onSelect: (CalendarEvent) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Left colored border
            Rectangle()
                .fill(event.resolvedColor)
                .frame(width: CalendarLayout.eventCardBorderWidth)

            // Content
            VStack(alignment: .leading, spacing: 1) {
                Text(event.summary)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(height > 36 ? 2 : 1)

                if height > 28 {
                    Text(timeRangeText)
                        .font(.system(size: 9, weight: .regular))
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
            event.resolvedColor.opacity(CalendarSemanticColor.eventCardBackgroundOpacity)
        )
        .clipShape(.rect(cornerRadius: CornerRadius.sm))
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .shadow(
            color: isHovered ? event.resolvedColor.opacity(0.2) : .clear,
            radius: isHovered ? 4 : 0,
            y: isHovered ? 2 : 0
        )
        .animation(VikAnimation.springDefault, value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect(event) }
        .accessibilityLabel("\(event.summary), \(timeRangeText)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Private

    private var timeRangeText: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        if event.isAllDay {
            return "All day"
        }
        return "\(formatter.string(from: event.startTime)) – \(formatter.string(from: event.endTime))"
    }
}

// MARK: - Preview

#Preview {
    let event = CalendarEvent(
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
