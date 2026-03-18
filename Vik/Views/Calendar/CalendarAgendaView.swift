import SwiftUI

// MARK: - CalendarAgendaView

/// Chronological event list grouped by date with sticky section headers.
/// Loads 30 days starting from `viewModel.selectedDate`; omits empty days.
struct CalendarAgendaView: View {

    @Bindable var viewModel: CalendarViewModel
    let onSelectEvent: (CalendarEvent) -> Void

    // MARK: - Computed data

    /// 30-day window of dates with at least one event, starting from selectedDate.
    private var groupedDays: [(date: Date, events: [CalendarEvent])] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: viewModel.selectedDate)
        return (0..<30).compactMap { offset -> (Date, [CalendarEvent])? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let dayEvents = viewModel.eventsForDay(day)
                .sorted { lhs, rhs in
                    // All-day events first, then by start time
                    if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                    return lhs.startTime < rhs.startTime
                }
            guard !dayEvents.isEmpty else { return nil }
            return (day, dayEvents)
        }
    }

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
        .animation(VikAnimation.contentSwitch, value: viewModel.selectedDate)
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

    private func relativeDayLabel(_ date: Date, isToday: Bool, isTomorrow: Bool) -> String {
        if isToday { return "Today" }
        if isTomorrow { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private func fullDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return formatter.string(from: date)
    }
}

// MARK: - AgendaEventRow

/// Glass card row for an event in the agenda list.
private struct AgendaEventRow: View {
    let event: CalendarEvent
    let onSelect: (CalendarEvent) -> Void

    @State private var isHovered = false

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
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    // Title
                    Text(event.summary)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    // Metadata row
                    HStack(spacing: Spacing.md) {
                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "mappin")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if event.attendees.count > 0 {
                            Label("\(event.attendees.count)", systemImage: "person.2")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        if event.conferenceLink != nil {
                            Image(systemName: "video")
                                .font(.system(size: 12))
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
            .scaleEffect(isHovered ? ScaleToken.hover : 1.0)
            .animation(VikAnimation.springSnappy, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var timeString: String {
        if event.isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        let amPmFormatter = DateFormatter()
        amPmFormatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: event.startTime)) – \(amPmFormatter.string(from: event.endTime))"
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarAgendaView(viewModel: vm, onSelectEvent: { _ in })
        .frame(width: 500, height: 600)
}
