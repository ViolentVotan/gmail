import SwiftUI

// MARK: - CalendarMiniMonthView

struct CalendarMiniMonthView: View {
    @Bindable var viewModel: CalendarViewModel

    private let calendar = Calendar.current
    private let dayColumns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private let daySymbols = ["S", "M", "T", "W", "T", "F", "S"]

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
                withAnimation(VikAnimation.springSnappy) {
                    viewModel.navigateBackward()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Text(monthYearText)
                .font(Typography.captionSemibold)
                .foregroundStyle(.primary)
                .monospacedDigit()

            Spacer()

            Button {
                withAnimation(VikAnimation.springSnappy) {
                    viewModel.navigateForward()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Day of Week Header

    private var dayOfWeekHeader: some View {
        HStack(spacing: 0) {
            ForEach(daySymbols.indices, id: \.self) { index in
                Text(daySymbols[index])
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Days Grid

    private var daysGrid: some View {
        let weeks = weeksInMonth()
        return VStack(spacing: 2) {
            ForEach(weeks.indices, id: \.self) { weekIndex in
                weekRow(weeks[weekIndex], isSelectedWeek: isSelectedWeek(weeks[weekIndex]))
            }
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
        .background(
            isSelectedWeek
                ? BrandColor.blue.opacity(OpacityToken.tag)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: CornerRadius.xs)
        )
    }

    private func dayCell(_ date: Date, inSelectedWeek: Bool) -> some View {
        let isToday = calendar.isDateInToday(date)
        let isSelected = calendar.isDate(date, inSameDayAs: viewModel.selectedDate)
        let isInCurrentMonth = calendar.isDate(date, equalTo: viewModel.selectedDate, toGranularity: .month)

        return Button {
            withAnimation(VikAnimation.springSnappy) {
                viewModel.selectDate(date)
            }
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 11, weight: isToday ? .bold : .regular))
                .foregroundStyle(dayTextColor(isToday: isToday, isSelected: isSelected, isInMonth: isInCurrentMonth))
                .frame(width: CalendarLayout.miniMonthDaySize, height: CalendarLayout.miniMonthDaySize)
                .background(
                    isToday
                        ? CalendarSemanticColor.todayHeaderCircle
                        : Color.clear,
                    in: Circle()
                )
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var monthYearText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: viewModel.selectedDate)
    }

    private func dayTextColor(isToday: Bool, isSelected: Bool, isInMonth: Bool) -> some ShapeStyle {
        if isToday { return AnyShapeStyle(.white) }
        if !isInMonth { return AnyShapeStyle(.tertiary) }
        return AnyShapeStyle(.primary)
    }

    private func isSelectedWeek(_ days: [Date?]) -> Bool {
        days.compactMap { $0 }.contains { calendar.isDate($0, equalTo: viewModel.selectedDate, toGranularity: .weekOfYear) }
    }

    private func weeksInMonth() -> [[Date?]] {
        let components = calendar.dateComponents([.year, .month], from: viewModel.selectedDate)
        guard let firstOfMonth = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth)
        else { return [] }

        let firstWeekday = calendar.component(.weekday, from: firstOfMonth) - 1
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
                    let date = calendar.date(byAdding: .day, value: offset, to: firstOfMonth)
                    weekDays.append(date)
                }
            }
            weeks.append(weekDays)
        }
        return weeks
    }
}

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarMiniMonthView(viewModel: vm)
        .frame(width: 220)
        .padding()
}
