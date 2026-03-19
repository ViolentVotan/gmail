import SwiftUI

// MARK: - Spanning Layout Algorithm

/// Placement of a single spanning bar in the week row.
struct SpanningBarPlacement: Sendable {
    let event: CalendarEvent
    let startColumn: Int
    let endColumn: Int
    let rowIndex: Int
    let isClippedAtStart: Bool
    let isClippedAtEnd: Bool
}

/// Result of computing spanning bar layout for one week row.
struct MonthSpanningLayout: Sendable {
    let rows: [SpanningBarPlacement]
    /// Number of spanning events that overflowed (beyond monthMaxSpanningRows) per day column (0-6).
    let overflowPerDay: [Int]

    static func compute(events: [CalendarEvent], weekDays: [Date]) -> MonthSpanningLayout {
        let cal = Calendar.current
        let weekStart = cal.startOfDay(for: weekDays[0])
        let weekEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: weekDays[6]))!

        let spanning = events.filter { event in
            let isMultiDay = event.isAllDay || cal.startOfDay(for: event.startTime) != cal.startOfDay(for: event.endTime)
            let overlaps = event.startTime < weekEnd && event.endTime > weekStart
            return isMultiDay && overlaps
        }
        .sorted { a, b in
            let aDuration = a.endTime.timeIntervalSince(a.startTime)
            let bDuration = b.endTime.timeIntervalSince(b.startTime)
            if aDuration != bDuration { return aDuration > bDuration }
            return a.startTime < b.startTime
        }

        let maxRows = CalendarLayout.monthMaxSpanningRows
        var occupied: [[Bool]] = Array(repeating: Array(repeating: false, count: 7), count: maxRows)
        var placements: [SpanningBarPlacement] = []
        var overflow = Array(repeating: 0, count: 7)

        for event in spanning {
            let eventStart = max(cal.startOfDay(for: event.startTime), weekStart)
            let eventEnd = min(
                event.isAllDay ? cal.startOfDay(for: event.endTime) : cal.startOfDay(for: event.endTime),
                cal.startOfDay(for: weekDays[6])
            )
            let startCol = cal.dateComponents([.day], from: weekStart, to: eventStart).day ?? 0
            let endCol = cal.dateComponents([.day], from: weekStart, to: eventEnd).day ?? 0
            let clampedStart = max(0, min(6, startCol))
            let clampedEnd = max(clampedStart, min(6, endCol))

            var assignedRow: Int?
            for row in 0..<maxRows {
                let isFree = (clampedStart...clampedEnd).allSatisfy { !occupied[row][$0] }
                if isFree {
                    assignedRow = row
                    for col in clampedStart...clampedEnd {
                        occupied[row][col] = true
                    }
                    break
                }
            }

            if let row = assignedRow {
                let eventStartDay = cal.startOfDay(for: event.startTime)
                let eventEndDay = cal.startOfDay(for: event.isAllDay ? event.endTime : max(event.startTime, event.endTime.addingTimeInterval(-1)))
                placements.append(SpanningBarPlacement(
                    event: event,
                    startColumn: clampedStart,
                    endColumn: clampedEnd,
                    rowIndex: row,
                    isClippedAtStart: eventStartDay < weekStart,
                    isClippedAtEnd: eventEndDay > cal.startOfDay(for: weekDays[6])
                ))
            } else {
                for col in clampedStart...clampedEnd {
                    overflow[col] += 1
                }
            }
        }

        return MonthSpanningLayout(rows: placements, overflowPerDay: overflow)
    }
}

// MARK: - Day Cell Content

/// Pre-computed content for a single day cell in the month grid.
struct MonthDayCellContent: Identifiable {
    var id: Date { date }
    let date: Date
    let visibleChips: [CalendarEvent]
    let visibleSpanningBarCount: Int
    let overflowCount: Int
    let isInCurrentMonth: Bool
}

// MARK: - CalendarMonthView

struct CalendarMonthView: View {
    @Bindable var viewModel: CalendarViewModel
    var onSelectEvent: (CalendarEvent) -> Void = { _ in }
    var onCreateEvent: (Date, Int) -> Void = { _, _ in }
    var onEdit: (CalendarEvent) -> Void = { _ in }
    var onDelete: (CalendarEvent) -> Void = { _ in }
    var onRSVP: (CalendarEvent, CalendarRSVPStatus) -> Void = { _, _ in }
    var onEmailAttendees: (CalendarEvent) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hoveredDate: Date?
    @State private var spanningBarColumnWidth: CGFloat = 0
    @State private var cachedWeeks: [[Date]] = []
    @State private var cachedCurrentMonth: Int = 0
    @State private var cachedSpanningLayouts: [MonthSpanningLayout] = []
    @State private var cachedCellContents: [[MonthDayCellContent]] = []
    @State private var orderedShortSymbols: [String] = []
    @State private var orderedFullSymbols: [String] = []

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            dayOfWeekHeader

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(cachedWeeks.enumerated()), id: \.offset) { weekIndex, weekDays in
                        if weekIndex > 0 {
                            Divider()
                        }
                        weekRow(
                            weekDays: weekDays,
                            currentMonth: cachedCurrentMonth,
                            weekIndex: weekIndex,
                            spanningLayout: weekIndex < cachedSpanningLayouts.count ? cachedSpanningLayouts[weekIndex] : MonthSpanningLayout(rows: [], overflowPerDay: Array(repeating: 0, count: 7)),
                            cellContents: weekIndex < cachedCellContents.count ? cachedCellContents[weekIndex] : []
                        )
                        .containerRelativeFrame(.vertical, count: 6, span: 1, spacing: 0)
                    }
                }
            }
        }
        .task {
            recomputeWeekdaySymbols()
        }
        .task(id: viewModel.selectedDate) { recomputeMonthLayout() }
        .onChange(of: viewModel.events) { recomputeMonthLayout() }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            recomputeWeekdaySymbols()
        }
    }

    private func recomputeMonthLayout() {
        let weeks = calendar.weeksInMonth(for: viewModel.selectedDate)
        let currentMonth = calendar.component(.month, from: viewModel.selectedDate)

        var layouts: [MonthSpanningLayout] = []
        var contents: [[MonthDayCellContent]] = []

        for weekDays in weeks {
            let layout = MonthSpanningLayout.compute(
                events: viewModel.multiDayEvents,
                weekDays: weekDays
            )
            let cells = computeCellContents(
                weekDays: weekDays,
                currentMonth: currentMonth,
                spanningLayout: layout
            )
            layouts.append(layout)
            contents.append(cells)
        }

        cachedWeeks = weeks
        cachedCurrentMonth = currentMonth
        cachedSpanningLayouts = layouts
        cachedCellContents = contents
    }

    // MARK: - Day of Week Header

    private var dayOfWeekHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(orderedShortSymbols.enumerated()), id: \.offset) { index, symbol in
                Text(symbol.uppercased())
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xs)
                    .accessibilityLabel(index < orderedFullSymbols.count ? orderedFullSymbols[index] : symbol)
            }
        }
        .padding(.horizontal, 1)
        .background(.bar)
    }

    private func recomputeWeekdaySymbols() {
        let firstWeekday = calendar.firstWeekday
        let shortSymbols = calendar.shortWeekdaySymbols
        let fullSymbols = calendar.weekdaySymbols
        orderedShortSymbols = Array(shortSymbols[(firstWeekday - 1)...]) + Array(shortSymbols[..<(firstWeekday - 1)])
        orderedFullSymbols = Array(fullSymbols[(firstWeekday - 1)...]) + Array(fullSymbols[..<(firstWeekday - 1)])
    }

    // MARK: - Week Row

    private func weekRow(
        weekDays: [Date],
        currentMonth: Int,
        weekIndex: Int,
        spanningLayout: MonthSpanningLayout,
        cellContents: [MonthDayCellContent]
    ) -> some View {
        VStack(spacing: 0) {
            if !spanningLayout.rows.isEmpty {
                spanningBarArea(layout: spanningLayout)
            }

            HStack(spacing: 0) {
                ForEach(Array(cellContents.enumerated()), id: \.offset) { colIndex, content in
                    if colIndex > 0 {
                        Divider()
                    }
                    dayCell(content: content)
                }
            }
        }
    }

    // MARK: - Spanning Bar Area

    private func spanningBarArea(layout: MonthSpanningLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, placement in
                CalendarMonthSpanningBar(
                    event: placement.event,
                    startColumn: placement.startColumn,
                    endColumn: placement.endColumn,
                    columnWidth: spanningBarColumnWidth,
                    isClippedAtStart: placement.isClippedAtStart,
                    isClippedAtEnd: placement.isClippedAtEnd,
                    onSelect: { onSelectEvent($0) }
                )
                .offset(y: CGFloat(placement.rowIndex) * CalendarLayout.monthSpanningBarHeight)
            }
        }
        .frame(height: CGFloat(
            min(layout.rows.map(\.rowIndex).max().map { $0 + 1 } ?? 0, CalendarLayout.monthMaxSpanningRows)
        ) * CalendarLayout.monthSpanningBarHeight)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width / 7
        } action: { newWidth in
            spanningBarColumnWidth = newWidth
        }
    }

    // MARK: - Day Cell

    @ViewBuilder
    private func dayCell(content: MonthDayCellContent) -> some View {
        let isToday = calendar.isDateInToday(content.date)
        let isWeekend = calendar.isDateInWeekend(content.date)

        VStack(alignment: .leading, spacing: 1) {
            dayNumber(date: content.date, isToday: isToday, isInMonth: content.isInCurrentMonth)

            ForEach(content.visibleChips, id: \.id) { event in
                CalendarMonthEventChip(event: event) { selected in
                    onSelectEvent(selected)
                }
            }

            if content.overflowCount > 0 {
                overflowButton(count: content.overflowCount, date: content.date)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isToday ? CalendarSemanticColor.todayHighlight : Color.clear)
        .background(
            hoveredDate == content.date ? CalendarSemanticColor.monthCellHover : Color.clear,
            in: .rect(cornerRadius: 0)
        )
        .opacity(
            !content.isInCurrentMonth ? CalendarSemanticColor.monthOverflowDayOpacity
            : isWeekend ? CalendarSemanticColor.weekendColumnOpacity
            : 1.0
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : VikAnimation.springDefault) {
                hoveredDate = hovering ? content.date : nil
            }
        }
        .onTapGesture {
            onCreateEvent(content.date, 9)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(content.date.formatted(date: .complete, time: .omitted)), \(content.visibleChips.count + content.overflowCount) events"
        )
    }

    // MARK: - Day Number

    @ViewBuilder
    private func dayNumber(date: Date, isToday: Bool, isInMonth: Bool) -> some View {
        let dayText = "\(calendar.component(.day, from: date))"

        Button {
            withAnimation(VikAnimation.springSnappy) {
                viewModel.selectDate(date)
                viewModel.viewMode = .day
            }
        } label: {
            Text(dayText)
                .font(Typography.caption)
                .fontWeight(isToday ? .bold : .regular)
                .foregroundStyle(dayNumberForeground(isToday: isToday, isInMonth: isInMonth))
                .frame(width: 22, height: 22)
                .background {
                    if isToday {
                        Circle()
                            .fill(CalendarSemanticColor.todayHeaderCircle)
                            .glassEffect(.regular, in: .circle)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .contentShape(Circle())
        .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted))")
        .accessibilityHint("Switch to day view")
        .accessibilityAddTraits(isToday ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Overflow Button

    private func overflowButton(count: Int, date: Date) -> some View {
        MonthOverflowButton(count: count) {
            viewModel.selectDate(date)
            viewModel.viewMode = .day
        }
    }

    // MARK: - Helpers

    private func computeCellContents(
        weekDays: [Date],
        currentMonth: Int,
        spanningLayout: MonthSpanningLayout
    ) -> [MonthDayCellContent] {
        let eventsByDay = viewModel.eventsByDay

        return weekDays.enumerated().map { colIndex, date in
            let dayStart = calendar.startOfDay(for: date)
            let allEvents = eventsByDay[dayStart] ?? []

            let singleDayEvents = allEvents.filter { event in
                !event.isAllDay && calendar.startOfDay(for: event.startTime) == calendar.startOfDay(for: event.endTime)
            }
            let singleDayAllDay = allEvents.filter { event in
                event.isAllDay && calendar.startOfDay(for: event.startTime) == calendar.startOfDay(for: event.endTime)
            }
            let chipCandidates = singleDayAllDay + singleDayEvents.sorted { $0.startTime < $1.startTime }

            let visibleSpanCount = spanningLayout.rows.filter {
                $0.startColumn <= colIndex && $0.endColumn >= colIndex
            }.count

            let remainingSlots = max(0, CalendarLayout.monthViewMaxEventsPerCell - visibleSpanCount)
            let visibleChips = Array(chipCandidates.prefix(remainingSlots))
            let chipOverflow = max(0, chipCandidates.count - remainingSlots)
            let spanOverflow = spanningLayout.overflowPerDay[colIndex]

            return MonthDayCellContent(
                date: date,
                visibleChips: visibleChips,
                visibleSpanningBarCount: visibleSpanCount,
                overflowCount: chipOverflow + spanOverflow,
                isInCurrentMonth: calendar.component(.month, from: date) == currentMonth
            )
        }
    }

    private func dayNumberForeground(isToday: Bool, isInMonth: Bool) -> Color {
        if isToday { return .white }
        if !isInMonth { return Color(nsColor: .tertiaryLabelColor) }
        return Color(nsColor: .labelColor)
    }
}

// MARK: - MonthOverflowButton

/// Overflow button with hover/press feedback matching the chip interaction pattern.
struct MonthOverflowButton: View {
    let count: Int
    var action: () -> Void = {}

    @State private var isHovered = false
    @GestureState private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("+\(count) more")
            .font(Typography.calendarEventTime)
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(.horizontal, Spacing.xs)
            .frame(height: CalendarLayout.monthEventChipHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                isHovered ? .regular.interactive() : .identity,
                in: .rect(cornerRadius: CornerRadius.sm)
            )
            .scaleEffect(reduceMotion ? 1.0 : (isPressed ? ScaleToken.press : (isHovered ? ScaleToken.rowHover : 1.0)))
            .animation(reduceMotion ? nil : VikAnimation.springSnappy, value: isPressed)
            .animation(reduceMotion ? nil : VikAnimation.springDefault, value: isHovered)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in state = true }
                    .onEnded { _ in action() }
            )
            .onHover { isHovered = $0 }
            .contentShape(Rectangle())
            .accessibilityLabel("\(count) more events")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarMonthView(viewModel: vm)
        .frame(width: 1000, height: 700)
}
