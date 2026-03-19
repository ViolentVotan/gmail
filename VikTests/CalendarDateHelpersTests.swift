import Testing
import Foundation
@testable import Vik

@Suite("Calendar Date Helpers")
struct CalendarDateHelpersTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2  // Monday start
        return cal
    }()

    @Test("weeksInMonth returns 6 weeks of 7 dates each")
    func weeksInMonthReturns6x7() {
        let march2026 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let weeks = calendar.weeksInMonth(for: march2026)
        #expect(weeks.count == 6)
        for week in weeks {
            #expect(week.count == 7)
        }
    }

    @Test("First cell is Monday of the week containing the 1st")
    func firstCellIsMonday() {
        let march2026 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let weeks = calendar.weeksInMonth(for: march2026)
        let firstDay = weeks[0][0]
        #expect(calendar.component(.weekday, from: firstDay) == 2) // Monday
        #expect(calendar.component(.day, from: firstDay) == 23)    // Feb 23
        #expect(calendar.component(.month, from: firstDay) == 2)
    }

    @Test("Last cell is Sunday, 42 days after first cell")
    func lastCellIsSunday() {
        let march2026 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let weeks = calendar.weeksInMonth(for: march2026)
        let lastDay = weeks[5][6]
        #expect(calendar.component(.weekday, from: lastDay) == 1) // Sunday
    }

    @Test("All dates are contiguous (each day is exactly 1 day after previous)")
    func datesAreContiguous() {
        let march2026 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let weeks = calendar.weeksInMonth(for: march2026)
        let allDates = weeks.flatMap { $0 }
        for i in 1..<allDates.count {
            let diff = calendar.dateComponents([.day], from: allDates[i - 1], to: allDates[i]).day
            #expect(diff == 1)
        }
    }
}
