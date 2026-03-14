import Foundation

extension Date {
    // MARK: - Cached formatters

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let shortDateYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static let mediumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let longMediumTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .medium
        return f
    }()

    private static let longShortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // MARK: - Formatted properties

    /// Formats a date relative to today: time for today, "Yesterday", or "MMM d" otherwise.
    var formattedRelative: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return Self.timeFormatter.string(from: self)
        } else if calendar.isDateInYesterday(self) {
            return "Yesterday"
        } else if calendar.component(.year, from: self) != calendar.component(.year, from: Date()) {
            return Self.shortDateYearFormatter.string(from: self)
        } else {
            return Self.shortDateFormatter.string(from: self)
        }
    }

    /// Medium date with short time: "Mar 1, 2025, 2:34 PM".
    var formattedMedium: String {
        Self.mediumFormatter.string(from: self)
    }

    /// Long date with medium time: "March 1, 2025 at 2:34:56 PM".
    var formattedLong: String {
        Self.longMediumTimeFormatter.string(from: self)
    }

    /// Long date with short time: "March 1, 2025 at 2:34 PM".
    var formattedLongShort: String {
        Self.longShortTimeFormatter.string(from: self)
    }

    /// Medium date only: "Mar 1, 2025".
    var formattedDateOnly: String {
        Self.dateOnlyFormatter.string(from: self)
    }
}
