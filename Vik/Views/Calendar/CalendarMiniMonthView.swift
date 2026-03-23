import SwiftUI

// MARK: - CalendarMiniMonthView

struct CalendarMiniMonthView: View {
    @Bindable var viewModel: CalendarViewModel

    @State private var cachedWeeks: [[Date?]] = []
    @State private var cachedMonth: Int = -1
    @State private var cachedYear: Int = -1
    @State private var selectedWeekIndex: Int? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let dayColumns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private static let daySymbols: [String] = {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let firstWeekday = Calendar.current.firstWeekday
        return Array(symbols[(firstWeekday - 1)...]) + Array(symbols[..<(firstWeekday - 1)])
    }()

    var body: some View {
        VStack(spacing: Spacing.xs) {
            monthHeader
            dayOfWeekHeader
            daysGrid
        }
    }

    // MARK: - Month Header

    private var monthHeader: some View {
        HStack {
            Button {
                withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                    viewModel.navigateBackward()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(Typography.calendarMiniEventTitle)
                    .frame(width: ButtonSize.md, height: ButtonSize.md)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .foregroundStyle(.secondary)
            .help("Previous month")
            .accessibilityLabel("Previous month")

            Spacer()

            Text(monthYearText)
                .font(Typography.captionSemibold)
                .foregroundStyle(.primary)
                .monospacedDigit()

            Spacer()

            Button {
                withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                    viewModel.navigateForward()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(Typography.calendarMiniEventTitle)
                    .frame(width: ButtonSize.md, height: ButtonSize.md)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .foregroundStyle(.secondary)
            .help("Next month")
            .accessibilityLabel("Next month")
        }
    }

    // MARK: - Day of Week Header

    private var dayOfWeekHeader: some View {
        HStack(spacing: 0) {
            ForEach(Self.daySymbols.indices, id: \.self) { index in
                Text(Self.daySymbols[index])
                    .font(Typography.calendarMiniWeekday)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Days Grid

    private var daysGrid: some View {
        GlassEffectContainer {
            VStack(spacing: 2) {
                ForEach(cachedWeeks.indices, id: \.self) { weekIndex in
                    weekRow(cachedWeeks[weekIndex], isSelectedWeek: weekIndex == selectedWeekIndex)
                }
            }
        }
        .task {
            recomputeWeeksIfNeeded()
        }
        .onChange(of: viewModel.selectedDate) {
            recomputeWeeksIfNeeded()
        }
    }

    private func weekRow(_ days: [Date?], isSelectedWeek: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(days.indices, id: \.self) { dayIndex in
                if let date = days[dayIndex] {
                    dayCell(date, inSelectedWeek: isSelectedWeek)
                } else {
                    Color.clear
                        .frame(width: CalendarLayout.miniMonthDaySize, height: CalendarLayout.miniMonthDaySize)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .glassEffect(
            isSelectedWeek ? .regular.interactive() : .identity,
            in: .rect(cornerRadius: CornerRadius.xs)
        )
    }

    @ViewBuilder
    private func dayCell(_ date: Date, inSelectedWeek: Bool) -> some View {
        let cal = Calendar.current
        let hasEvents = !viewModel.eventsForDay(date).isEmpty
        MiniMonthDayCell(
            date: date,
            dayNumber: cal.component(.day, from: date),
            isToday: cal.isDateInToday(date),
            isSelected: cal.isDate(date, inSameDayAs: viewModel.selectedDate),
            isInCurrentMonth: cal.isDate(date, equalTo: viewModel.selectedDate, toGranularity: .month),
            hasEvents: hasEvents,
            onSelectDate: { viewModel.selectDate($0) }
        )
    }

    // MARK: - Helpers

    private var monthYearText: String {
        viewModel.selectedDate.formattedMonthYear
    }

    private func recomputeWeeksIfNeeded() {
        let cal = Calendar.current
        let month = cal.component(.month, from: viewModel.selectedDate)
        let year = cal.component(.year, from: viewModel.selectedDate)
        let needsFullRecompute = month != cachedMonth || year != cachedYear
        if needsFullRecompute {
            cachedMonth = month
            cachedYear = year
            cachedWeeks = weeksInMonth()
        }
        selectedWeekIndex = cachedWeeks.firstIndex { days in
            days.compactMap { $0 }.contains { cal.isDate($0, equalTo: viewModel.selectedDate, toGranularity: .weekOfYear) }
        }
    }

    private func weeksInMonth() -> [[Date?]] {
        let cal = Calendar.current
        let components = cal.dateComponents([.year, .month], from: viewModel.selectedDate)
        guard let firstOfMonth = cal.date(from: components),
              let range = cal.range(of: .day, in: .month, for: firstOfMonth)
        else { return [] }

        let weekdayOfFirst = cal.component(.weekday, from: firstOfMonth)
        let firstWeekday = (weekdayOfFirst - cal.firstWeekday + 7) % 7
        let totalDays = range.count
        let totalCells = firstWeekday + totalDays
        let totalWeeks = Int(ceil(Double(totalCells) / 7.0))

        var weeks: [[Date?]] = []
        for week in 0..<totalWeeks {
            var weekDays: [Date?] = []
            for day in 0..<7 {
                let offset = week * 7 + day - firstWeekday
                if offset < 0 || offset >= totalDays {
                    weekDays.append(nil)
                } else {
                    let date = cal.date(byAdding: .day, value: offset, to: firstOfMonth)
                    weekDays.append(date)
                }
            }
            weeks.append(weekDays)
        }
        return weeks
    }
}

// MARK: - MiniMonthDayCell

/// Extracted day cell with local hover state to avoid invalidating the entire mini-month grid on hover.
private struct MiniMonthDayCell: View {
    let date: Date
    let dayNumber: Int
    let isToday: Bool
    let isSelected: Bool
    let isInCurrentMonth: Bool
    let hasEvents: Bool
    let onSelectDate: (Date) -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {

        Button {
            withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                onSelectDate(date)
            }
        } label: {
            Text("\(dayNumber)")
                .font(isToday ? Typography.calendarMiniDay.bold() : Typography.calendarMiniDay)
                .foregroundStyle(dayTextColor(isToday: isToday, isSelected: isSelected, isInMonth: isInCurrentMonth))
                .frame(width: CalendarLayout.miniMonthDaySize, height: CalendarLayout.miniMonthDaySize)
                .background(
                    isToday
                        ? CalendarSemanticColor.todayHeaderCircle
                        : Color.clear,
                    in: Circle()
                )
                .glassEffect(
                    isToday || isSelected || isHovered ? .regular.interactive() : .identity,
                    in: .circle
                )
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: isHovered)
        .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted))\(hasEvents ? ", has events" : "")")
        .accessibilityAddTraits(isToday ? [.isButton, .isSelected] : .isButton)
        .accessibilityHidden(!isInCurrentMonth)
    }

    private func dayTextColor(isToday: Bool, isSelected: Bool, isInMonth: Bool) -> Color {
        if isToday { return .white }
        if !isInMonth { return Color(nsColor: .tertiaryLabelColor) }
        return Color(nsColor: .labelColor)
    }
}

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarMiniMonthView(viewModel: vm)
        .frame(width: 220)
        .padding()
}
