import SwiftUI

// MARK: - CalendarWeekView

struct CalendarWeekView: View {
    @Bindable var viewModel: CalendarViewModel
    var onSelectEvent: (CalendarEvent) -> Void
    var onCreateEvent: (Date, Int) -> Void

    @State private var currentTime: Date = .now
    @State private var scrollProxy: ScrollViewProxy?

    private let hours = Array(0..<24)

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h a"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private static let accessibilityDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }()

    var body: some View {
        let weekDays = computeWeekDays()
        GeometryReader { geo in
            let dayColumnWidth = (geo.size.width - CalendarLayout.timeColumnWidth) / 7

            VStack(spacing: 0) {
                allDaySection(weekDays: weekDays, dayColumnWidth: dayColumnWidth)
                Divider()
                dayHeaderRow(weekDays: weekDays, dayColumnWidth: dayColumnWidth)
                Divider()
                timeGrid(weekDays: weekDays, dayColumnWidth: dayColumnWidth)
            }
            .clipped()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                currentTime = .now
            }
        }
    }

    // MARK: - All-Day Section

    @ViewBuilder
    private func allDaySection(weekDays: [Date], dayColumnWidth: CGFloat) -> some View {
        let allDayByDay = weekDays.map { day in
            viewModel.eventsForDay(day).filter { $0.isAllDay }
        }
        let maxCount = allDayByDay.map(\.count).max() ?? 0

        if maxCount > 0 {
            HStack(spacing: 0) {
                // Time column spacer
                Text("all-day")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .frame(width: CalendarLayout.timeColumnWidth, alignment: .trailing)
                    .padding(.trailing, Spacing.xs)
                    .accessibilityHidden(true)

                // All-day chips per day
                ForEach(Array(allDayByDay.enumerated()), id: \.offset) { _, allDayEvents in
                    VStack(spacing: 2) {
                        ForEach(allDayEvents) { event in
                            allDayChip(event: event, width: dayColumnWidth)
                        }
                    }
                    .frame(width: dayColumnWidth)
                    .padding(.vertical, Spacing.xs)
                }
            }
            .frame(height: CGFloat(max(1, maxCount)) * (CalendarLayout.allDayEventHeight + 2) + Spacing.sm)
        }
    }

    private func allDayChip(event: CalendarEvent, width: CGFloat) -> some View {
        Button {
            onSelectEvent(event)
        } label: {
            Text(event.summary)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, Spacing.xs)
                .frame(height: CalendarLayout.allDayEventHeight)
                .frame(width: width - 2, alignment: .leading)
                .background(event.resolvedColor, in: .rect(cornerRadius: CornerRadius.xs))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.summary), all day")
    }

    // MARK: - Day Header Row

    private func dayHeaderRow(weekDays: [Date], dayColumnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Empty time column header
            Spacer()
                .frame(width: CalendarLayout.timeColumnWidth)
                .accessibilityHidden(true)

            ForEach(weekDays, id: \.self) { day in
                dayHeader(for: day, width: dayColumnWidth)
            }
        }
        .padding(.vertical, Spacing.xs)
        .background(.bar)
    }

    private func dayHeader(for date: Date, width: CGFloat) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        let weekdayAbbrev = weekdayAbbreviation(for: date)
        let dayNumber = Calendar.current.component(.day, from: date)
        let accessibilityLabel = Self.accessibilityDayFormatter.string(from: date)

        return VStack(spacing: 2) {
            Text(weekdayAbbrev)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isToday ? BrandColor.blue : .secondary)

            ZStack {
                if isToday {
                    Circle()
                        .fill(CalendarSemanticColor.todayHeaderCircle)
                        .frame(width: 26, height: 26)
                }
                Text("\(dayNumber)")
                    .font(.system(size: 13, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? .white : .primary)
            }
        }
        .frame(width: width)
        .accessibilityLabel(isToday ? "\(accessibilityLabel), today" : accessibilityLabel)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Time Grid

    private func timeGrid(weekDays: [Date], dayColumnWidth: CGFloat) -> some View {
        let timedEventsByDay = buildTimedEventsByDay(weekDays: weekDays)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    // Background grid
                    gridBackground(weekDays: weekDays, dayColumnWidth: dayColumnWidth)

                    // Events overlay
                    eventsOverlay(
                        weekDays: weekDays,
                        timedEventsByDay: timedEventsByDay,
                        dayColumnWidth: dayColumnWidth
                    )

                    // Current time indicator
                    currentTimeIndicator(weekDays: weekDays, dayColumnWidth: dayColumnWidth)
                }
                .frame(height: CGFloat(hours.count) * CalendarLayout.hourRowHeight)
            }
            .task {
                scrollProxy = proxy
                // Scroll to current hour minus 1 so context is visible above
                let hour = max(Calendar.current.component(.hour, from: .now) - 1, 0)
                proxy.scrollTo("hour-\(hour)", anchor: .top)
            }
        }
    }

    // MARK: - Grid Background

    private func gridBackground(weekDays: [Date], dayColumnWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(hours, id: \.self) { hour in
                HStack(spacing: 0) {
                    // Hour label
                    Text(hourLabel(for: hour))
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .frame(width: CalendarLayout.timeColumnWidth, alignment: .trailing)
                        .padding(.trailing, Spacing.xs)
                        .offset(y: -7)
                        .accessibilityHidden(true)

                    // Day columns with grid lines
                    HStack(spacing: 0) {
                        ForEach(0..<weekDays.count, id: \.self) { dayIndex in
                            let day = weekDays[dayIndex]
                            let isToday = Calendar.current.isDateInToday(day)
                            let isWeekend = isWeekend(day)

                            Rectangle()
                                .fill(
                                    isToday
                                    ? CalendarSemanticColor.todayHighlight
                                    : isWeekend
                                    ? Color.primary.opacity(CalendarSemanticColor.weekendColumnOpacity * 0.02)
                                    : Color.clear
                                )
                                .frame(width: dayColumnWidth)
                                .overlay(alignment: .top) {
                                    // Horizontal hour divider
                                    Divider()
                                        .opacity(0.04)
                                }
                                .overlay(alignment: .trailing) {
                                    // Vertical column divider
                                    if dayIndex < weekDays.count - 1 {
                                        Divider()
                                            .opacity(0.06)
                                    }
                                }
                        }
                    }
                }
                .frame(height: CalendarLayout.hourRowHeight)
                .id("hour-\(hour)")
                .contentShape(Rectangle())
                .accessibilityLabel(hour == 0 ? "Create event at midnight" : "Create event at \(hourLabel(for: hour))")
                .accessibilityAddTraits(.isButton)
                .onTapGesture { [hour] in
                    onCreateEvent(dateForTap(hour: hour), hour)
                }
            }
        }
    }

    // MARK: - Events Overlay

    private func eventsOverlay(
        weekDays: [Date],
        timedEventsByDay: [Date: [CalendarEvent]],
        dayColumnWidth: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<weekDays.count, id: \.self) { dayIndex in
                dayEventsOverlay(
                    dayIndex: dayIndex,
                    day: weekDays[dayIndex],
                    timedEvents: timedEventsByDay[weekDays[dayIndex]] ?? [],
                    dayColumnWidth: dayColumnWidth
                )
            }
        }
    }

    @ViewBuilder
    private func dayEventsOverlay(
        dayIndex: Int,
        day: Date,
        timedEvents: [CalendarEvent],
        dayColumnWidth: CGFloat
    ) -> some View {
        let groups = overlapGroups(for: timedEvents)
        ForEach(0..<groups.count, id: \.self) { groupIndex in
            let group = groups[groupIndex]
            ForEach(Array(group.enumerated()), id: \.element.id) { colIndex, event in
                eventCard(
                    event: event,
                    dayIndex: dayIndex,
                    colIndex: colIndex,
                    colCount: group.count,
                    dayColumnWidth: dayColumnWidth
                )
            }
        }
    }

    @ViewBuilder
    private func eventCard(
        event: CalendarEvent,
        dayIndex: Int,
        colIndex: Int,
        colCount: Int,
        dayColumnWidth: CGFloat
    ) -> some View {
        let yOffset = yPosition(for: event.startTime)
        let height = eventHeight(for: event)
        let colWidth = (dayColumnWidth - 4) / CGFloat(colCount)
        let xOffset = CalendarLayout.timeColumnWidth
            + CGFloat(dayIndex) * dayColumnWidth
            + CGFloat(colIndex) * colWidth
            + 2
        CalendarEventCard(event: event, height: height) { ev in
            onSelectEvent(ev)
        }
        .frame(width: colWidth - 1)
        .offset(x: xOffset, y: yOffset)
    }

    // MARK: - Current Time Indicator

    @ViewBuilder
    private func currentTimeIndicator(weekDays: [Date], dayColumnWidth: CGFloat) -> some View {
        let todayIndex = weekDays.firstIndex { Calendar.current.isDateInToday($0) }
        if let index = todayIndex {
            let yPos = yPosition(for: currentTime)
            let xStart = CalendarLayout.timeColumnWidth + CGFloat(index) * dayColumnWidth

            ZStack(alignment: .leading) {
                // Red line
                Rectangle()
                    .fill(CalendarSemanticColor.currentTimeIndicator)
                    .frame(height: CalendarLayout.currentTimeIndicatorHeight)
                    .frame(width: dayColumnWidth)
                    .offset(x: xStart + CalendarLayout.currentTimeIndicatorDotSize / 2)

                // Red dot
                Circle()
                    .fill(CalendarSemanticColor.currentTimeIndicator)
                    .frame(
                        width: CalendarLayout.currentTimeIndicatorDotSize,
                        height: CalendarLayout.currentTimeIndicatorDotSize
                    )
                    .offset(x: xStart)
            }
            .offset(y: yPos - CalendarLayout.currentTimeIndicatorDotSize / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Helpers

    private func computeWeekDays() -> [Date] {
        let week = viewModel.selectedWeek
        var days: [Date] = []
        days.reserveCapacity(7)
        var current = week.start
        for _ in 0..<7 {
            days.append(current)
            current = Calendar.current.date(byAdding: .day, value: 1, to: current) ?? current
        }
        return days
    }

    /// Partitions timed (non-all-day) events for each day into a lookup dictionary.
    private func buildTimedEventsByDay(weekDays: [Date]) -> [Date: [CalendarEvent]] {
        var result: [Date: [CalendarEvent]] = Dictionary(minimumCapacity: weekDays.count)
        for day in weekDays {
            result[day] = viewModel.eventsForDay(day).filter { !$0.isAllDay }
        }
        return result
    }

    private func weekdayAbbreviation(for date: Date) -> String {
        Self.weekdayFormatter.string(from: date).uppercased()
    }

    private func isWeekend(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    private func hourLabel(for hour: Int) -> String {
        guard hour > 0 else { return "" }
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return Self.hourFormatter.string(from: date)
    }

    private func yPosition(for date: Date) -> CGFloat {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hours = CGFloat(comps.hour ?? 0)
        let minutes = CGFloat(comps.minute ?? 0)
        return (hours + minutes / 60.0) * CalendarLayout.hourRowHeight
    }

    private func eventHeight(for event: CalendarEvent) -> CGFloat {
        let durationSeconds = event.endTime.timeIntervalSince(event.startTime)
        let durationHours = CGFloat(durationSeconds) / 3600.0
        return max(durationHours * CalendarLayout.hourRowHeight, CalendarLayout.eventCardMinHeight)
    }

    private func dateForTap(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: viewModel.selectedDate) ?? viewModel.selectedDate
    }

    /// Groups overlapping timed events into columns for side-by-side layout.
    private func overlapGroups(for events: [CalendarEvent]) -> [[CalendarEvent]] {
        let sorted = events.sorted { $0.startTime < $1.startTime }
        var groups: [[CalendarEvent]] = []
        var currentGroup: [CalendarEvent] = []
        var groupEnd: Date = .distantPast

        for event in sorted {
            if event.startTime < groupEnd {
                // Overlaps with existing group
                currentGroup.append(event)
                if event.endTime > groupEnd { groupEnd = event.endTime }
            } else {
                // New non-overlapping group
                if !currentGroup.isEmpty { groups.append(currentGroup) }
                currentGroup = [event]
                groupEnd = event.endTime
            }
        }
        if !currentGroup.isEmpty { groups.append(currentGroup) }
        return groups
    }
}
