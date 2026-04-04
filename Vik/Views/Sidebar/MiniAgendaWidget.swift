import SwiftUI

// MARK: - MiniAgendaWidget

struct MiniAgendaWidget: View {
    let events: [CalendarEvent]
    var onSelectEvent: (CalendarEvent) -> Void
    var onShowCalendar: () -> Void

    @State private var cachedSortedEvents: [CalendarEvent] = []
    @State private var isEvening: Bool = false
    @State private var headerTitle: String = "Today"
    @State private var hoveredEventID: String?
    @State private var isHeaderHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            headerRow
            if cachedSortedEvents.isEmpty {
                emptyState
            } else {
                eventsList
            }
        }
        .padding(Spacing.sm)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.lg))
        .task {
            recomputeSortedEvents()
            updateHeaderState()
        }
        .onChange(of: events) {
            recomputeSortedEvents()
            updateHeaderState()
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        Button(action: onShowCalendar) {
            HStack {
                Text(headerTitle.uppercased())
                    .font(Typography.calendarEventTitle)
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Typography.calendarMiniWeekday)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .glassEffect(isHeaderHovered ? .regular.interactive() : .identity, in: .rect(cornerRadius: CornerRadius.sm))
        .onHover { isHeaderHovered = $0 }
        .accessibilityLabel("\(headerTitle) calendar events")
        .accessibilityHint("Opens full calendar view")
    }

    private var eventsList: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(cachedSortedEvents) { event in
                eventRow(event)
            }
        }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        let timeLabel = event.isAllDay ? "All day" : eventTimeText(event)
        return Button {
            onSelectEvent(event)
        } label: {
            HStack(spacing: Spacing.xs) {
                RoundedRectangle(cornerRadius: CornerRadius.xxs)
                    .fill(event.resolvedColor)
                    .frame(width: 3)
                    .frame(height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.summary)
                        .font(Typography.calendarMiniEventTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if event.isAllDay {
                        Text("All day")
                            .font(Typography.calendarMiniEventTime)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: Spacing.xs) {
                            Text(timeLabel)
                                .font(Typography.calendarMiniEventTime)
                                .foregroundStyle(.secondary)

                            if isHappeningNow(event) {
                                nowBadge
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(hoveredEventID == event.id ? .regular.interactive() : .identity, in: .rect(cornerRadius: CornerRadius.sm))
        .onHover { hovering in
            hoveredEventID = hovering ? event.id : nil
        }
        .accessibilityLabel("\(event.summary), \(timeLabel)")
        .accessibilityHint("Opens event details")
    }

    private var nowBadge: some View {
        Text("Now")
            .font(Typography.captionSmall)
            .foregroundStyle(Color.contrastingForeground(for: NSColor(BrandColor.blue)))
            .padding(.horizontal, 5)
            .padding(.vertical, Spacing.xxxs)
            .background(BrandColor.blue, in: Capsule())
    }

    private var emptyState: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "calendar")
                .font(Typography.subheadRegular)
                .foregroundStyle(.tertiary)
            Text("No events today")
                .font(Typography.calendarAgendaTime)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Spacing.xxs)
    }

    // MARK: - Helpers

    private func updateHeaderState() {
        let hour = Calendar.current.component(.hour, from: Date())
        let evening = hour >= 18
        let hasMoreEvents = events.contains { !$0.isAllDay && $0.endTime > Date() }
        isEvening = evening
        headerTitle = (evening && !hasMoreEvents) ? "Tomorrow" : "Today"
    }

    private func recomputeSortedEvents() {
        let (allDay, timed) = events.partitioned()
        let sortedTimed = timed.sorted { $0.startTime < $1.startTime }
        cachedSortedEvents = Array((allDay + sortedTimed).prefix(CalendarLayout.miniAgendaMaxEvents))
    }

    private func eventTimeText(_ event: CalendarEvent) -> String {
        "\(event.startTime.formattedCalendarTime) – \(event.endTime.formattedCalendarTimeAmPm)"
    }

    private func isHappeningNow(_ event: CalendarEvent) -> Bool {
        let now = Date()
        return event.startTime <= now && event.endTime > now
    }
}

#Preview {
    let now = Date()
    let events: [CalendarEvent] = [
        CalendarEvent(
            id: "test_primary_1",
            googleEventId: "1",
            calendarId: "primary",
            accountID: "test",
            summary: "Team Standup",
            description: nil,
            location: nil,
            startTime: now,
            endTime: now.addingTimeInterval(1800),
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
        ),
        CalendarEvent(
            id: "test_primary_2",
            googleEventId: "2",
            calendarId: "primary",
            accountID: "test",
            summary: "Design Review",
            description: nil,
            location: nil,
            startTime: now.addingTimeInterval(3600),
            endTime: now.addingTimeInterval(5400),
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
            resolvedColor: BrandColor.coral,
            isRecurring: false,
            recurringEventId: nil,
            reminders: [],
            eventType: .default,
            etag: "",
            htmlLink: nil,
            canEdit: true,
            attachments: []
        )
    ]

    MiniAgendaWidget(
        events: events,
        onSelectEvent: { _ in },
        onShowCalendar: { }
    )
    .frame(width: 220)
    .padding()
}
