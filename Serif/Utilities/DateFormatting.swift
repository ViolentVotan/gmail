import Foundation

extension Date {
    /// Formats a date relative to today: time for today, "Yesterday", or "MMM d" otherwise.
    var formattedRelative: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(self) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDateInYesterday(self) {
            return "Yesterday"
        } else if calendar.component(.year, from: self) != calendar.component(.year, from: Date()) {
            formatter.dateFormat = "MMM d, yyyy"
        } else {
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: self)
    }
}
