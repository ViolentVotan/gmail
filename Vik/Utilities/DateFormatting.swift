import Foundation

extension Date {
    // MARK: - Cached formatters

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()

    private static let shortDateYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
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

    private static let gmailQueryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    // MARK: - Calendar formatters

    private static let calendarTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()

    private static let calendarTimeAmPmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let calendarHourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h a"
        return f
    }()

    private static let weekdayShortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private static let weekdayFullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        return f
    }()

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()

    private static let fullDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    private static let accessibilityDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }()

    private static let allDayISOFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - RFC 2822 formatters

    private static let rfc2822WriteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        f.timeZone = TimeZone.autoupdatingCurrent
        return f
    }()

    private static let rfc2822ReadFormatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss z"
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
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

    /// Time only, respecting locale (e.g. "2:34 PM" or "14:34").
    var formattedTime: String {
        Self.timeFormatter.string(from: self)
    }

    /// Gmail API query format: "2026/03/14".
    var formattedGmailQuery: String {
        Self.gmailQueryFormatter.string(from: self)
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

    /// Calendar time without AM/PM: "2:30".
    var formattedCalendarTime: String {
        Self.calendarTimeFormatter.string(from: self)
    }

    /// Calendar time with AM/PM: "2:30 PM".
    var formattedCalendarTimeAmPm: String {
        Self.calendarTimeAmPmFormatter.string(from: self)
    }

    /// Calendar hour label: "2 PM".
    var formattedCalendarHour: String {
        Self.calendarHourFormatter.string(from: self)
    }

    /// Month and year: "March 2026".
    var formattedMonthYear: String {
        Self.monthYearFormatter.string(from: self)
    }

    /// Short weekday: "Mon".
    var formattedWeekdayShort: String {
        Self.weekdayShortFormatter.string(from: self)
    }

    /// Full weekday: "Monday".
    var formattedWeekdayFull: String {
        Self.weekdayFullFormatter.string(from: self)
    }

    /// Month and day: "March 21".
    var formattedMonthDay: String {
        Self.monthDayFormatter.string(from: self)
    }

    /// Full date: "Friday, March 21, 2026".
    var formattedFullDate: String {
        Self.fullDateFormatter.string(from: self)
    }

    /// Full date with short time: "Friday, March 21, 2026 at 2:30 PM".
    var formattedFullDateTime: String {
        Self.fullDateTimeFormatter.string(from: self)
    }

    /// Accessibility day: "Monday, March 21".
    var formattedAccessibilityDay: String {
        Self.accessibilityDayFormatter.string(from: self)
    }

    /// All-day ISO date: "2026-03-21".
    var formattedAllDayISO: String {
        Self.allDayISOFormatter.string(from: self)
    }

    /// Short date without year: "Mar 21".
    var formattedShortDate: String {
        Self.shortDateFormatter.string(from: self)
    }

    /// Short date with year: "Mar 21, 2026".
    var formattedShortDateYear: String {
        Self.shortDateYearFormatter.string(from: self)
    }

    /// RFC 2822 formatted string for use in outgoing message headers.
    /// Creates a fresh formatter per call to avoid data races from concurrent sends.
    var formattedRFC2822: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        f.timeZone = TimeZone.autoupdatingCurrent
        return f.string(from: self)
    }

    /// Parses an RFC 2822 date string, trying multiple format variants.
    static func parseRFC2822(_ string: String) -> Date? {
        for parser in rfc2822ReadFormatters {
            if let date = parser.date(from: string) { return date }
        }
        return nil
    }
}
