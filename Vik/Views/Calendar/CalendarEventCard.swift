import SwiftUI

// MARK: - CalendarEventCard

struct CalendarEventCard: View {
    /// Controls layout density: `.compact` for week view, `.detailed` for day view.
    enum Style {
        case compact
        case detailed
    }

    let event: CalendarEvent
    var height: CGFloat = 0
    var style: Style = .compact
    let onSelect: (CalendarEvent) -> Void

    private let timeRangeText: String

    @State private var isHovered = false
    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(event: CalendarEvent, height: CGFloat = 0, style: Style = .compact, onSelect: @escaping (CalendarEvent) -> Void) {
        self.event = event
        self.height = height
        self.style = style
        self.onSelect = onSelect
        self.timeRangeText = event.isAllDay ? "All day" : "\(event.startTime.formattedTime) – \(event.endTime.formattedTime)"
    }

    var body: some View {
        Button { onSelect(event) } label: {
            HStack(spacing: 0) {
                leftBorder
                content
            }
            .modifier(CardChrome(
                event: event,
                style: style,
                height: height,
                isHovered: isHovered,
                isPressed: isPressed,
                reduceMotion: reduceMotion
            ))
        }
        .buttonStyle(PressTrackingButtonStyle(isPressed: $isPressed))
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(event.summary), \(timeRangeText)")
        .accessibilityHint("Opens event details")
        .accessibilityAddTraits(.isButton)
        .help(event.summary)
    }

    // MARK: - Left border

    @ViewBuilder
    private var leftBorder: some View {
        switch style {
        case .compact:
            Rectangle()
                .fill(event.resolvedColor)
                .frame(width: CalendarLayout.eventCardBorderWidth)
        case .detailed:
            RoundedRectangle(cornerRadius: CalendarLayout.eventCardBorderWidth / 2)
                .fill(event.resolvedColor)
                .frame(width: CalendarLayout.eventCardBorderWidth)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch style {
        case .compact:
            compactContent
        case .detailed:
            detailedContent
        }
    }

    private var compactContent: some View {
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
        .padding(.vertical, Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailedContent: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary)
                    .font(Typography.calendarEventTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(event.formattedTimeRangeCompact)
                    .font(Typography.calendarEventTime)
                    .foregroundStyle(.secondary)

                if let description = event.description, !description.isEmpty {
                    Text(description)
                        .font(Typography.calendarEventTime)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if event.attendees.count > 0 || event.conferenceLink != nil {
                    HStack(spacing: Spacing.sm) {
                        if event.attendees.count > 0 {
                            Label("\(event.attendees.count)", systemImage: "person.2")
                                .font(Typography.calendarEventTime)
                                .foregroundStyle(.secondary)
                        }
                        if event.conferenceLink != nil {
                            Image(systemName: "video")
                                .font(Typography.calendarEventTime)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xs)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Card Chrome

    /// Shared background, glass, scale, and shadow treatment.
    private struct CardChrome: ViewModifier {
        let event: CalendarEvent
        let style: Style
        let height: CGFloat
        let isHovered: Bool
        let isPressed: Bool
        let reduceMotion: Bool

        private var cornerRadius: CGFloat {
            style == .compact ? CornerRadius.sm : CornerRadius.xs
        }

        func body(content: Content) -> some View {
            content
                .frame(height: style == .compact ? max(height, CalendarLayout.eventCardMinHeight) : nil)
                .background(
                    event.resolvedColor.opacity(CalendarSemanticColor.eventCardBackgroundOpacity),
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .overlay(style == .detailed
                    ? AnyView(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(
                                event.resolvedColor.opacity(isHovered ? 0.4 : 0.2),
                                lineWidth: 0.5
                            )
                    )
                    : AnyView(EmptyView())
                )
                .glassEffect(
                    isHovered ? .regular.interactive() : .identity,
                    in: .rect(cornerRadius: cornerRadius)
                )
                .scaleEffect(reduceMotion ? 1.0 : (isPressed ? ScaleToken.press : (isHovered ? ScaleToken.hover : 1.0)))
                .shadow(
                    color: isHovered ? event.resolvedColor.opacity(style == .compact ? OpacityToken.accent : 0.2) : .clear,
                    radius: isHovered ? 4 : 0,
                    y: isHovered ? 2 : 0
                )
                .animation(reduceMotion ? nil : VikAnimation.springSnappy, value: isPressed)
                .animation(reduceMotion ? nil : (style == .compact ? VikAnimation.springDefault : VikAnimation.springSnappy), value: isHovered)
        }
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
