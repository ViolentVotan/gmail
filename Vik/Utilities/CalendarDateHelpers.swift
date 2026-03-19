import Foundation

extension Calendar {
    /// Returns 6 weeks of 7 dates each for the month containing `date`.
    /// Weeks start on Monday. Overflow days from adjacent months fill the grid.
    func weeksInMonth(for date: Date) -> [[Date]] {
        let components = dateComponents([.year, .month], from: date)
        let firstOfMonth = self.date(from: components)!
        let weekday = component(.weekday, from: firstOfMonth)
        // Days back to Monday: (weekday - 2 + 7) % 7  (weekday: 1=Sun..7=Sat)
        let mondayOffset = (weekday - 2 + 7) % 7
        let gridStart = self.date(byAdding: .day, value: -mondayOffset, to: firstOfMonth)!

        var weeks: [[Date]] = []
        for week in 0..<6 {
            var weekDays: [Date] = []
            for day in 0..<7 {
                let offset = week * 7 + day
                let cellDate = self.date(byAdding: .day, value: offset, to: gridStart)!
                weekDays.append(startOfDay(for: cellDate))
            }
            weeks.append(weekDays)
        }
        return weeks
    }
}
