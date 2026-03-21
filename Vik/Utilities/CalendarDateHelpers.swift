import Foundation

extension [CalendarEvent] {
    /// Groups overlapping timed events into clusters for side-by-side column layout.
    func overlapGroups() -> [[CalendarEvent]] {
        let sorted = self.sorted { $0.startTime < $1.startTime }
        var groups: [[CalendarEvent]] = []
        var currentGroup: [CalendarEvent] = []
        var groupEnd: Date = .distantPast
        for event in sorted {
            if event.startTime < groupEnd {
                currentGroup.append(event)
                if event.endTime > groupEnd { groupEnd = event.endTime }
            } else {
                if !currentGroup.isEmpty { groups.append(currentGroup) }
                currentGroup = [event]
                groupEnd = event.endTime
            }
        }
        if !currentGroup.isEmpty { groups.append(currentGroup) }
        return groups
    }
}

extension Calendar {
    /// Returns 6 weeks of 7 dates each for the month containing `date`.
    /// Weeks start on `self.firstWeekday` (locale-dependent). Overflow days from adjacent months fill the grid.
    func weeksInMonth(for date: Date) -> [[Date]] {
        let components = dateComponents([.year, .month], from: date)
        let firstOfMonth = self.date(from: components)!
        let weekday = component(.weekday, from: firstOfMonth)
        let offset = (weekday - self.firstWeekday + 7) % 7
        let gridStart = self.date(byAdding: .day, value: -offset, to: firstOfMonth)!

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
