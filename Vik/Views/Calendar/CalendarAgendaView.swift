import SwiftUI

// MARK: - CalendarAgendaView

/// Chronological event list grouped by date with sticky section headers.
/// Loads 30 days starting from `viewModel.selectedDate`; omits empty days.
struct CalendarAgendaView: View {

    @Bindable var viewModel: CalendarViewModel
    let onSelectEvent: (CalendarEvent) -> Void
    var onEdit: (CalendarEvent) -> Void = { _ in }
    var onDelete: (CalendarEvent) -> Void = { _ in }
    var onRSVP: (CalendarEvent, CalendarRSVPStatus) -> Void = { _, _ in }
    var onEmailAttendees: (CalendarEvent) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var groupedDays: [(date: Date, events: [CalendarEvent])] = []

    // MARK: - Body

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if groupedDays.isEmpty {
                    emptyState
                } else {
                    ForEach(groupedDays, id: \.date) { group in
                        Section {
                            ForEach(group.events) { event in
                                AgendaEventRow(event: event, onSelect: onSelectEvent)
                                    .contextMenu {
                                        CalendarEventContextMenu(
                                            event: event,
                                            onEdit: onEdit,
                                            onDelete: onDelete,
                                            onRSVP: onRSVP,
                                            onEmailAttendees: onEmailAttendees
                                        )
                                    }
                                    .padding(.horizontal, Spacing.md)
                                    .padding(.bottom, Spacing.xs)
                            }
                        } header: {
                            sectionHeader(for: group.date)
                        }
                    }
                }
            }
            .padding(.bottom, Spacing.xxl)
        }
        .animation(reduceMotion ? nil : VikAnimation.contentSwitch, value: viewModel.selectedDate)
        .task(id: viewModel.selectedDate) {
            recomputeGroupedDays()
        }
        .onChange(of: viewModel.events) {
            recomputeGroupedDays()
        }
        .accessibilityRotor("Today's Events") {
            ForEach(viewModel.events.filter { Calendar.current.isDateInToday($0.startTime) }) { event in
                AccessibilityRotorEntry(event.summary, id: event.id)
            }
        }
    }

    // MARK: - Section header

    private func sectionHeader(for date: Date) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(date)
        let isTomorrow = calendar.isDateInTomorrow(date)

        return HStack(spacing: Spacing.sm) {
            // Today accent line
            if isToday {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(BrandColor.blue)
                    .frame(width: CalendarLayout.eventCardBorderWidth, height: 16)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(relativeDayLabel(date, isToday: isToday, isTomorrow: isTomorrow))
                    .font(isToday ? Typography.captionSemibold : Typography.captionRegular)
                    .foregroundStyle(isToday ? BrandColor.blue : .primary)
                Text(fullDateLabel(date))
                    .font(Typography.captionSmallRegular)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(.regularMaterial)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(relativeDayLabel(date, isToday: isToday, isTomorrow: isTomorrow)), \(fullDateLabel(date))")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "calendar")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No upcoming events")
                .font(Typography.subheadRegular)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xxl * 2)
    }

    // MARK: - Helpers

    /// Recomputes the 30-day grouped event list from the ViewModel.
    private func recomputeGroupedDays() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: viewModel.selectedDate)
        groupedDays = (0..<30).compactMap { offset -> (Date, [CalendarEvent])? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let dayEvents = viewModel.eventsForDay(day)
                .sorted { lhs, rhs in
                    if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                    return lhs.startTime < rhs.startTime
                }
            guard !dayEvents.isEmpty else { return nil }
            return (day, dayEvents)
        }
    }

    private static let dayOfWeekFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return formatter
    }()

    private func relativeDayLabel(_ date: Date, isToday: Bool, isTomorrow: Bool) -> String {
        if isToday { return "Today" }
        if isTomorrow { return "Tomorrow" }
        return Self.dayOfWeekFormatter.string(from: date)
    }

    private func fullDateLabel(_ date: Date) -> String {
        Self.monthDayFormatter.string(from: date)
    }
}

// MARK: - AgendaEventRow

/// Glass card row for an event in the agenda list.
private struct AgendaEventRow: View {
    let event: CalendarEvent
    let onSelect: (CalendarEvent) -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPast: Bool {
        event.endTime < .now && !Calendar.current.isDateInToday(event.startTime)
    }

    var body: some View {
        Button {
            onSelect(event)
        } label: {
            HStack(spacing: Spacing.sm) {
                // Left calendar color bar
                RoundedRectangle(cornerRadius: CalendarLayout.eventCardBorderWidth / 2)
                    .fill(event.resolvedColor)
                    .frame(width: CalendarLayout.eventCardBorderWidth)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 3) {
                    // Time
                    Text(timeString)
                        .font(Typography.calendarAgendaTime)
                        .foregroundStyle(.secondary)

                    // Title
                    Text(event.summary)
                        .font(Typography.calendarAgendaTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    // Metadata row
                    HStack(spacing: Spacing.md) {
                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "mappin")
                                .font(Typography.calendarAgendaTime)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if event.attendees.count > 0 {
                            Label("\(event.attendees.count)", systemImage: "person.2")
                                .font(Typography.calendarAgendaTime)
                                .foregroundStyle(.secondary)
                        }
                        if event.conferenceLink != nil {
                            Image(systemName: "video")
                                .font(Typography.calendarAgendaTime)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(Spacing.sm)
            .background(
                event.resolvedColor.opacity(isHovered
                    ? CalendarSemanticColor.eventCardBackgroundOpacity * 1.5
                    : CalendarSemanticColor.eventCardBackgroundOpacity),
                in: RoundedRectangle(cornerRadius: CornerRadius.sm)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .strokeBorder(
                        event.resolvedColor.opacity(isHovered ? 0.3 : 0.15),
                        lineWidth: 0.5
                    )
            )
            .opacity(isPast ? OpacityToken.secondary : 1.0)
            .scaleEffect(reduceMotion ? 1.0 : (isHovered ? ScaleToken.hover : 1.0))
            .animation(reduceMotion ? nil : VikAnimation.springSnappy, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(timeString), \(event.summary)")
        .accessibilityAddTraits(.isButton)
    }

    private var timeString: String {
        if event.isAllDay { return "All day" }
        return "\(event.startTime.formattedCalendarTime) – \(event.endTime.formattedCalendarTimeAmPm)"
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarAgendaView(viewModel: vm, onSelectEvent: { _ in })
        .frame(width: 500, height: 600)
}
