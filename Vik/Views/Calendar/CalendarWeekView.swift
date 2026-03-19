import SwiftUI

// MARK: - CalendarWeekView

struct CalendarWeekView: View {
    @Bindable var viewModel: CalendarViewModel
    var onSelectEvent: (CalendarEvent) -> Void
    var onCreateEvent: (Date, Int) -> Void

    @State private var currentTime: Date = .now
    @State private var scrollProxy: ScrollViewProxy?
    @State private var cachedWeekDays: [Date] = []
    @State private var cachedTimedEventsByDay: [[CalendarEvent]] = []
    @State private var cachedAllDayEventsByDay: [[CalendarEvent]] = []
    @State private var cachedTodayIndex: Int? = nil
    @State private var cachedWeekendIndices: Set<Int> = []
    @State private var cachedOverlapGroupsByDay: [[[CalendarEvent]]] = []
    @State private var dayColumnWidth: CGFloat = 100

    private let hours = Array(0..<24)

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
        VStack(spacing: 0) {
            allDaySection(dayColumnWidth: dayColumnWidth)
            Divider()
            dayHeaderRow(dayColumnWidth: dayColumnWidth)
            Divider()
            timeGrid(dayColumnWidth: dayColumnWidth)
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            // Subtract the full time-gutter width (frame + trailing padding) to
            // reach a fixed point: content width = (timeColumnWidth + Spacing.xs) +
            // 7 * dayColumnWidth, so (content - timeColumnWidth - Spacing.xs) / 7
            // == dayColumnWidth — no growth per cycle.
            dayColumnWidth = (newWidth - CalendarLayout.timeColumnWidth - Spacing.xs) / 7
        }
        .task(id: viewModel.selectedDate) {
            recomputeCaches()
        }
        .onChange(of: viewModel.events) {
            recomputeCaches()
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
    private func allDaySection(dayColumnWidth: CGFloat) -> some View {
        let maxCount = cachedAllDayEventsByDay.map(\.count).max() ?? 0

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
                ForEach(Array(zip(cachedWeekDays, cachedAllDayEventsByDay)), id: \.0) { _, allDayEvents in
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
                .background(event.resolvedColor.opacity(0.8), in: .rect(cornerRadius: CornerRadius.xs))
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: CornerRadius.xs))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.summary), all day")
    }

    // MARK: - Day Header Row

    private func dayHeaderRow(dayColumnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Empty time column header
            Spacer()
                .frame(width: CalendarLayout.timeColumnWidth)
                .accessibilityHidden(true)

            ForEach(cachedWeekDays, id: \.self) { day in
                dayHeader(for: day, width: dayColumnWidth)
            }
        }
        .padding(.vertical, Spacing.xs)
        .background(.bar)
    }

    private func dayHeader(for date: Date, width: CGFloat) -> some View {
        let isToday = cachedWeekDays.firstIndex(of: date) == cachedTodayIndex
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
                        .glassEffect(.regular, in: .circle)
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

    private func timeGrid(dayColumnWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    // Background grid
                    gridBackground(dayColumnWidth: dayColumnWidth)

                    // Events overlay
                    eventsOverlay(dayColumnWidth: dayColumnWidth)

                    // Current time indicator
                    currentTimeIndicator(dayColumnWidth: dayColumnWidth)
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

    private func gridBackground(dayColumnWidth: CGFloat) -> some View {
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
                        ForEach(Array(cachedWeekDays.enumerated()), id: \.element) { dayIndex, day in
                            let isToday = dayIndex == cachedTodayIndex
                            let isWeekendDay = cachedWeekendIndices.contains(dayIndex)

                            Rectangle()
                                .fill(
                                    isToday
                                    ? CalendarSemanticColor.todayHighlight
                                    : isWeekendDay
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
                                    if day != cachedWeekDays.last {
                                        Divider()
                                            .opacity(0.04)
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

    private func eventsOverlay(dayColumnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(cachedWeekDays.enumerated()), id: \.element) { dayIndex, day in
                dayEventsOverlay(
                    dayIndex: dayIndex,
                    day: day,
                    timedEvents: dayIndex < cachedTimedEventsByDay.count ? cachedTimedEventsByDay[dayIndex] : [],
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
        let groups = dayIndex < cachedOverlapGroupsByDay.count ? cachedOverlapGroupsByDay[dayIndex] : []
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
        let yOffset = CalendarLayout.yPosition(for: event.startTime)
        let height = CalendarLayout.eventHeight(start: event.startTime, end: event.endTime, clampToMinHeight: true)
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
    private func currentTimeIndicator(dayColumnWidth: CGFloat) -> some View {
        if let index = cachedTodayIndex {
            let yPos = CalendarLayout.yPosition(for: currentTime)
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
            .animation(VikAnimation.springGentle, value: currentTime)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Helpers

    private func recomputeCaches() {
        let week = viewModel.selectedWeek
        var days: [Date] = []
        days.reserveCapacity(7)
        var current = week.start
        for _ in 0..<7 {
            days.append(current)
            current = Calendar.current.date(byAdding: .day, value: 1, to: current) ?? current
        }
        cachedWeekDays = days

        var timed: [[CalendarEvent]] = []
        var allDay: [[CalendarEvent]] = []
        timed.reserveCapacity(7)
        allDay.reserveCapacity(7)
        for day in days {
            let (dayAllDay, dayTimed) = viewModel.eventsForDay(day).partitioned()
            timed.append(dayTimed)
            allDay.append(dayAllDay)
        }
        cachedTimedEventsByDay = timed
        cachedAllDayEventsByDay = allDay
        cachedOverlapGroupsByDay = timed.map { overlapGroups(for: $0) }
        cachedTodayIndex = cachedWeekDays.firstIndex(where: { Calendar.current.isDateInToday($0) })
        cachedWeekendIndices = Set(cachedWeekDays.indices.filter { isWeekend(cachedWeekDays[$0]) })
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
        return date.formattedCalendarHour
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
