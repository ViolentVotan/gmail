import SwiftUI

// MARK: - CalendarWeekView

struct CalendarWeekView: View {
    @Bindable var viewModel: CalendarViewModel
    var onSelectEvent: (CalendarEvent) -> Void
    var onCreateEvent: (Date, Int) -> Void
    var onEdit: (CalendarEvent) -> Void = { _ in }
    var onDelete: (CalendarEvent) -> Void = { _ in }
    var onRSVP: (CalendarEvent, CalendarRSVPStatus) -> Void = { _, _ in }
    var onEmailAttendees: (CalendarEvent) -> Void = { _ in }

    @State private var currentTime: Date = .now
    @State private var scrollProxy: ScrollViewProxy?
    @State private var dayColumnWidth: CGFloat = 100

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct WeekLayoutCache {
        var weekDays: [Date] = []
        var timedEventsByDay: [[CalendarEvent]] = []
        var allDayEventsByDay: [[CalendarEvent]] = []
        var overlapGroupsByDay: [[[CalendarEvent]]] = []
        var todayIndex: Int? = nil
        var weekendIndices: Set<Int> = []
        var dayNumbers: [Int] = []
        var weekdayAbbrevs: [String] = []
    }

    @State private var weekCache = WeekLayoutCache()

    private let hours = Array(0..<24)


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
        .task(id: weekCache.todayIndex != nil) {
            guard weekCache.todayIndex != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                currentTime = .now
            }
        }
    }

    // MARK: - All-Day Section

    @ViewBuilder
    private func allDaySection(dayColumnWidth: CGFloat) -> some View {
        let maxCount = weekCache.allDayEventsByDay.lazy.map(\.count).max() ?? 0

        if maxCount > 0 {
            HStack(spacing: 0) {
                // Time column spacer
                Text("all-day")
                    .font(Typography.calendarWeekAllDayLabel)
                    .foregroundStyle(.tertiary)
                    .frame(width: CalendarLayout.timeColumnWidth, alignment: .trailing)
                    .padding(.trailing, Spacing.xs)
                    .accessibilityHidden(true)

                // All-day chips per day — shared container so glass effects merge
                GlassEffectContainer {
                    ForEach(weekCache.weekDays.indices, id: \.self) { index in
                        let allDayEvents = weekCache.allDayEventsByDay[index]
                        let dayDate = weekCache.weekDays[index]
                        VStack(spacing: 2) {
                            ForEach(allDayEvents) { event in
                                allDayChip(event: event, width: dayColumnWidth, dayDate: dayDate)
                            }
                        }
                        .frame(width: dayColumnWidth)
                        .padding(.vertical, Spacing.xs)
                    }
                }
            }
            .frame(height: CGFloat(max(1, maxCount)) * (CalendarLayout.allDayEventHeight + 2) + Spacing.sm)
        }
    }

    private func allDayChip(event: CalendarEvent, width: CGFloat, dayDate: Date? = nil) -> some View {
        let dayLabel = dayDate.map { ", \($0.formattedWeekdayFull)" } ?? ""
        return Button {
            onSelectEvent(event)
        } label: {
            Text(event.summary)
                .font(Typography.calendarWeekAllDayEvent)
                .foregroundStyle(CalendarColor.contrastingForeground(forId: Int(event.colorId ?? "")))
                .lineLimit(1)
                .padding(.horizontal, Spacing.xs)
                .frame(height: CalendarLayout.allDayEventHeight)
                .frame(width: width - 2, alignment: .leading)
                .background(event.resolvedColor.opacity(0.8), in: .rect(cornerRadius: CornerRadius.xs))
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: CornerRadius.xs))
        }
        .buttonStyle(.plain)
        .contextMenu {
            CalendarEventContextMenu(
                event: event,
                onEdit: onEdit,
                onDelete: onDelete,
                onRSVP: onRSVP,
                onEmailAttendees: onEmailAttendees
            )
        }
        .accessibilityLabel("\(event.summary), all day\(dayLabel)")
        .help(event.summary)
    }

    // MARK: - Day Header Row

    private func dayHeaderRow(dayColumnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Empty time column header
            Spacer()
                .frame(width: CalendarLayout.timeColumnWidth)
                .accessibilityHidden(true)

            // Shared container so today-circle glass merges with siblings
            GlassEffectContainer {
                ForEach(weekCache.weekDays.indices, id: \.self) { index in
                    dayHeader(for: weekCache.weekDays[index], index: index, width: dayColumnWidth)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .background(.bar)
    }

    private func dayHeader(for date: Date, index: Int, width: CGFloat) -> some View {
        let isToday = index == weekCache.todayIndex
        let weekdayAbbrev = index < weekCache.weekdayAbbrevs.count ? weekCache.weekdayAbbrevs[index] : date.formattedWeekdayShort.uppercased()
        let dayNumber = index < weekCache.dayNumbers.count ? weekCache.dayNumbers[index] : Calendar.current.component(.day, from: date)
        let accessibilityLabel = date.formattedAccessibilityDay

        return VStack(spacing: 2) {
            Text(weekdayAbbrev)
                .font(Typography.calendarWeekdayAbbrev)
                .foregroundStyle(isToday ? BrandColor.blue : .secondary)

            ZStack {
                if isToday {
                    Circle()
                        .fill(CalendarSemanticColor.todayHeaderCircle)
                        .frame(width: 26, height: 26)
                }
                Text("\(dayNumber)")
                    .font(Typography.calendarEventTitle)
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(isToday ? CalendarSemanticColor.todayHeaderText : .primary)
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
        let todayIdx = weekCache.todayIndex
        let weekendSet = weekCache.weekendIndices
        let dayCount = weekCache.weekDays.count
        let todayFill = CalendarSemanticColor.todayHighlight
        let weekendFill = Color.primary.opacity(CalendarSemanticColor.weekendColumnOpacity * 0.02)
        let dividerColor = Color.primary.opacity(0.04)

        return LazyVStack(spacing: 0) {
            ForEach(hours, id: \.self) { hour in
                HStack(spacing: 0) {
                    // Hour label
                    Text(hourLabel(for: hour))
                        .font(Typography.calendarWeekHourLabel)
                        .foregroundStyle(.tertiary)
                        .frame(width: CalendarLayout.timeColumnWidth, alignment: .trailing)
                        .padding(.trailing, Spacing.xs)
                        .offset(y: -7)
                        .accessibilityHidden(true)

                    // Day columns drawn via Canvas — replaces 7 Rectangles + ~13 Dividers per row
                    Canvas { context, size in
                        let rowHeight = size.height

                        for dayIndex in 0..<dayCount {
                            let x = CGFloat(dayIndex) * dayColumnWidth
                            let columnRect = CGRect(x: x, y: 0, width: dayColumnWidth, height: rowHeight)

                            // Column background fill
                            if dayIndex == todayIdx {
                                context.fill(Path(columnRect), with: .color(todayFill))
                            } else if weekendSet.contains(dayIndex) {
                                context.fill(Path(columnRect), with: .color(weekendFill))
                            }

                            // Horizontal hour divider at top
                            let hDivider = Path { p in
                                p.move(to: CGPoint(x: x, y: 0))
                                p.addLine(to: CGPoint(x: x + dayColumnWidth, y: 0))
                            }
                            context.stroke(hDivider, with: .color(dividerColor), lineWidth: 1)

                            // Vertical column divider on trailing edge (except last day)
                            if dayIndex < dayCount - 1 {
                                let vDivider = Path { p in
                                    p.move(to: CGPoint(x: x + dayColumnWidth, y: 0))
                                    p.addLine(to: CGPoint(x: x + dayColumnWidth, y: rowHeight))
                                }
                                context.stroke(vDivider, with: .color(dividerColor), lineWidth: 1)
                            }
                        }
                    }
                    .frame(width: dayColumnWidth * CGFloat(dayCount))
                }
                .frame(height: CalendarLayout.hourRowHeight)
                .id("hour-\(hour)")
                .contentShape(Rectangle())
                .accessibilityLabel(hour == 0 ? "Create event at midnight" : "Create event at \(hourLabel(for: hour))")
                .accessibilityAddTraits(.isButton)
                .help("Create event")
                .onTapGesture { [hour] in
                    onCreateEvent(dateForTap(hour: hour), hour)
                }
            }
        }
    }

    // MARK: - Events Overlay

    private func eventsOverlay(dayColumnWidth: CGFloat) -> some View {
        GlassEffectContainer {
            ZStack(alignment: .topLeading) {
                ForEach(weekCache.weekDays.indices, id: \.self) { dayIndex in
                    dayEventsOverlay(
                        dayIndex: dayIndex,
                        day: weekCache.weekDays[dayIndex],
                        timedEvents: dayIndex < weekCache.timedEventsByDay.count ? weekCache.timedEventsByDay[dayIndex] : [],
                        dayColumnWidth: dayColumnWidth
                    )
                }
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
        let groups = dayIndex < weekCache.overlapGroupsByDay.count ? weekCache.overlapGroupsByDay[dayIndex] : []
        ForEach(Array(groups.enumerated()), id: \.element.first?.id) { groupIndex, group in
            ForEach(Array(group.enumerated()), id: \.element.id) { colIndex, event in
                eventCard(
                    event: event,
                    dayIndex: dayIndex,
                    colIndex: colIndex,
                    colCount: group.count,
                    dayColumnWidth: dayColumnWidth,
                    startOfDay: day
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
        dayColumnWidth: CGFloat,
        startOfDay: Date
    ) -> some View {
        let yOffset = CalendarLayout.yPosition(for: event.startTime, startOfDay: startOfDay)
        let height = CalendarLayout.eventHeight(start: event.startTime, end: event.endTime, clampToMinHeight: true)
        let colWidth = (dayColumnWidth - 4) / CGFloat(colCount)
        let xOffset = CalendarLayout.timeColumnWidth
            + CGFloat(dayIndex) * dayColumnWidth
            + CGFloat(colIndex) * colWidth
            + 2
        CalendarEventCard(event: event, height: height) { ev in
            onSelectEvent(ev)
        }
        .contextMenu {
            CalendarEventContextMenu(
                event: event,
                onEdit: onEdit,
                onDelete: onDelete,
                onRSVP: onRSVP,
                onEmailAttendees: onEmailAttendees
            )
        }
        .frame(width: colWidth - 1)
        .offset(x: xOffset, y: yOffset)
    }

    // MARK: - Current Time Indicator

    @ViewBuilder
    private func currentTimeIndicator(dayColumnWidth: CGFloat) -> some View {
        if let index = weekCache.todayIndex {
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

        var timed: [[CalendarEvent]] = []
        var allDay: [[CalendarEvent]] = []
        timed.reserveCapacity(7)
        allDay.reserveCapacity(7)
        for day in days {
            let (dayAllDay, dayTimed) = viewModel.eventsForDay(day).partitioned()
            timed.append(dayTimed)
            allDay.append(dayAllDay)
        }

        var cache = WeekLayoutCache()
        let calendar = Calendar.current
        cache.weekDays = days
        cache.timedEventsByDay = timed
        cache.allDayEventsByDay = allDay
        cache.overlapGroupsByDay = timed.map { $0.overlapGroups() }
        cache.todayIndex = days.firstIndex(where: { calendar.isDateInToday($0) })
        cache.weekendIndices = Set(days.indices.filter { isWeekend(days[$0]) })
        cache.dayNumbers = days.map { calendar.component(.day, from: $0) }
        cache.weekdayAbbrevs = days.map { $0.formattedWeekdayShort.uppercased() }
        weekCache = cache
    }

    private func weekdayAbbreviation(for date: Date) -> String {
        date.formattedWeekdayShort.uppercased()
    }

    private func isWeekend(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    private func hourLabel(for hour: Int) -> String {
        CalendarLayout.hourLabels[hour]
    }

    private func dateForTap(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: viewModel.selectedDate) ?? viewModel.selectedDate
    }

}
