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

    private let calendar = Calendar.current

    var body: some View {
        let weeks = calendar.weeksInMonth(for: viewModel.selectedDate)
        let currentMonth = calendar.component(.month, from: viewModel.selectedDate)

        VStack(spacing: 0) {
            dayOfWeekHeader

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { weekIndex, weekDays in
                        if weekIndex > 0 {
                            Divider()
                        }
                        weekRow(
                            weekDays: weekDays,
                            currentMonth: currentMonth,
                            weekIndex: weekIndex
                        )
                        .containerRelativeFrame(.vertical, count: 6, span: 1, spacing: 0)
                    }
                }
            }
        }
    }

    // MARK: - Day of Week Header

    private var dayOfWeekHeader: some View {
        let ordered = {
            let symbols = calendar.shortWeekdaySymbols
            return Array(symbols[1...]) + [symbols[0]]
        }()

        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { index, symbol in
                Text(symbol.uppercased())
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xs)
                    .accessibilityLabel(calendar.weekdaySymbols[(index + 1) % 7])
            }
        }
        .padding(.horizontal, 1)
    }

    // MARK: - Week Row

    private func weekRow(weekDays: [Date], currentMonth: Int, weekIndex: Int) -> some View {
        let spanningLayout = MonthSpanningLayout.compute(
            events: viewModel.multiDayEvents,
            weekDays: weekDays
        )
        let cellContents = computeCellContents(
            weekDays: weekDays,
            currentMonth: currentMonth,
            spanningLayout: spanningLayout
        )

        return VStack(spacing: 0) {
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
        GeometryReader { geometry in
            let columnWidth = geometry.size.width / 7

            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, placement in
                    CalendarMonthSpanningBar(
                        event: placement.event,
                        startColumn: placement.startColumn,
                        endColumn: placement.endColumn,
                        columnWidth: columnWidth,
                        isClippedAtStart: placement.isClippedAtStart,
                        isClippedAtEnd: placement.isClippedAtEnd,
                        onSelect: { onSelectEvent($0) }
                    )
                    .offset(y: CGFloat(placement.rowIndex) * CalendarLayout.monthSpanningBarHeight)
                }
            }
        }
        .frame(height: CGFloat(
            min(layout.rows.map(\.rowIndex).max().map { $0 + 1 } ?? 0, CalendarLayout.monthMaxSpanningRows)
        ) * CalendarLayout.monthSpanningBarHeight)
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
        .opacity(
            !content.isInCurrentMonth ? CalendarSemanticColor.monthOverflowDayOpacity
            : isWeekend ? CalendarSemanticColor.weekendColumnOpacity
            : 1.0
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onCreateEvent(content.date, 9)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(content.date.formatted(date: .complete, time: .omitted)), \(content.visibleChips.count + content.overflowCount) events"
        )
    }

    // MARK: - Day Number

    private func dayNumber(date: Date, isToday: Bool, isInMonth: Bool) -> some View {
        let dayText = "\(calendar.component(.day, from: date))"

        return Button {
            withAnimation(VikAnimation.springSnappy) {
                viewModel.selectDate(date)
                viewModel.viewMode = .day
            }
        } label: {
            Text(dayText)
                .font(Typography.caption)
                .fontWeight(isToday ? .bold : .regular)
                .foregroundStyle(isToday ? AnyShapeStyle(.white) : isInMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 22, height: 22)
                .background {
                    if isToday {
                        Circle()
                            .fill(CalendarSemanticColor.todayHeaderCircle)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted))")
        .accessibilityHint("Switch to day view")
        .accessibilityAddTraits(isToday ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Overflow Button

    @ViewBuilder
    private func overflowButton(count: Int, date: Date) -> some View {
        Button {
            viewModel.selectDate(date)
            viewModel.viewMode = .day
        } label: {
            Text("+\(count) more")
                .font(Typography.calendarEventTime)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xs)
                .frame(height: CalendarLayout.monthEventChipHeight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) more events")
        .accessibilityAddTraits(.isButton)
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
}

// MARK: - Preview

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarMonthView(viewModel: vm)
        .frame(width: 1000, height: 700)
}
