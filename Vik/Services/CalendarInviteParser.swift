import Foundation
import Synchronization

// MARK: - Model

struct CalendarInvite: Equatable, Sendable {
    let summary: String
    let dateText: String
    let location: String?
    let organizer: String?
    var acceptURL: URL?
    var declineURL: URL?
    var maybeURL: URL?
    var rsvpStatus: RSVPStatus = .pending

    enum RSVPStatus: String, Equatable, Sendable { case accepted, declined, maybe, pending }

    /// Converts to the canonical `CalendarRSVPStatus` used by the calendar domain model.
    /// `maybe` maps to `tentative`; `pending` maps to `needsAction`.
    var calendarRSVPStatus: CalendarRSVPStatus {
        switch rsvpStatus {
        case .accepted: .accepted
        case .declined: .declined
        case .maybe:    .tentative
        case .pending:  .needsAction
        }
    }
}

// MARK: - Parser

enum CalendarInviteParser {

    // MARK: - Cached Regex

    private static let rsvpRegex: NSRegularExpression = {
        guard let regex = try? NSRegularExpression(
            pattern: #"https?://(?:www\.)?calendar\.google\.com/calendar/event\?action=RESPOND[^"'\s<>]*"#,
            options: .caseInsensitive
        ) else {
            preconditionFailure("Invalid regex pattern for rsvpRegex")
        }
        return regex
    }()

    private static let organizerRegex: NSRegularExpression = {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:Organizer|Organisateur|Organizado por)\s*:?\s*</(?:b|td|div|span)>\s*(?:</td>\s*<td[^>]*>)?\s*(.*?)(?=<|$)"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            preconditionFailure("Invalid regex pattern for organizerRegex")
        }
        return regex
    }()

    /// Detects a Google Calendar invitation from the HTML body.
    /// Returns nil if no RSVP URLs are found (not a calendar invite).
    static func parse(html: String, subject: String, sender: String) -> CalendarInvite? {
        let urls = extractRSVPURLs(from: html)
        // No RSVP URLs → not a calendar invite
        guard urls.accept != nil || urls.decline != nil || urls.maybe != nil else { return nil }

        let title = extractTitle(from: subject)
        let dateText = extractField(label: "When|Quand|Wann|Cuando", from: html) ?? ""
        let location = extractField(label: "Where|Où|Wo|Dónde|Location|Joining info|Informations de connexion", from: html)
        let organizer = extractOrganizer(from: html) ?? cleanSenderName(sender)

        return CalendarInvite(
            summary: title,
            dateText: dateText,
            location: location,
            organizer: organizer,
            acceptURL: urls.accept,
            declineURL: urls.decline,
            maybeURL: urls.maybe
        )
    }

    /// Sends a silent GET to the RSVP URL. Returns true on 2xx.
    /// Only allows HTTPS requests to calendar.google.com for safety.
    static func sendRSVP(url: URL) async -> Bool {
        guard url.scheme == "https",
              let host = url.host,
              host == "calendar.google.com" || host == "www.calendar.google.com"
        else { return false }

        do {
            let (_, response) = try await NetworkConfig.externalSession.data(from: url)
            if let http = response as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Private

    /// Extracts RSVP URLs from HTML body (Google Calendar rst=1/2/3 pattern).
    private static func extractRSVPURLs(from html: String) -> (accept: URL?, decline: URL?, maybe: URL?) {
        let range = NSRange(html.startIndex..., in: html)
        let matches = rsvpRegex.matches(in: html, range: range)

        var accept: URL?
        var decline: URL?
        var maybe: URL?

        for match in matches {
            guard let r = Range(match.range, in: html) else { continue }
            var urlString = String(html[r])
            urlString = urlString.replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: urlString) else { continue }

            if urlString.contains("rst=1") { accept = url }
            else if urlString.contains("rst=2") { decline = url }
            else if urlString.contains("rst=3") { maybe = url }
        }

        return (accept, decline, maybe)
    }

    /// Strips "Invitation:" / "Invitation :" prefix from subject to get the event title.
    private static func extractTitle(from subject: String) -> String {
        let prefixes = ["Invitation:", "Invitation :", "Invite:", "Invite :"]
        for prefix in prefixes {
            if subject.hasPrefix(prefix) {
                return subject.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return subject
    }

    /// Extracts a field value from Google Calendar HTML by label.
    /// Google uses patterns like `<b>When</b>` or table cells with the label followed by the value.
    /// Note: patterns are parameterized by label and compiled per call.
    private static func extractField(label: String, from html: String) -> String? {
        // Pattern 1: <b>Label</b> ... text content (up to next <b> or </td> or </div>)
        let pattern1 = #"<b>\s*(?:\#(label))\s*</b>\s*(?:</td>\s*<td[^>]*>)?\s*(.*?)(?=<b>|</td>|</div>|</tr>|<br\s*/?>)"#
        if let value = firstMatch(pattern: pattern1, in: html, group: 2) {
            let clean = value.strippingHTML
            if !clean.isEmpty { return clean }
        }

        // Pattern 2: td/div with label, next td/div with value
        let pattern2 = #"(?:\#(label))\s*:?\s*</(?:td|div|span|b)>\s*</td>\s*<td[^>]*>\s*(.*?)\s*</td>"#
        if let value = firstMatch(pattern: pattern2, in: html, group: 2) {
            let clean = value.strippingHTML
            if !clean.isEmpty { return clean }
        }

        return nil
    }

    /// Tries to find the organizer name from HTML (Google Calendar patterns).
    private static func extractOrganizer(from html: String) -> String? {
        let range = NSRange(html.startIndex..., in: html)
        guard let match = organizerRegex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: html)
        else { return nil }
        let clean = String(html[r]).strippingHTML
        return clean.isEmpty ? nil : clean
    }

    /// Extracts display name from "Name <email>" format.
    private static func cleanSenderName(_ sender: String) -> String {
        if let open = sender.firstIndex(of: "<") {
            return String(sender[sender.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        }
        return sender
    }

    private static let regexCache = Mutex<[String: NSRegularExpression]>([:])

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        regexCache.withLock { cache in
            if let cached = cache[pattern] { return cached }
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            cache[pattern] = regex
            return regex
        }
    }

    /// General-purpose regex match helper for parameterized patterns.
    private static func firstMatch(pattern: String, in text: String, group: Int) -> String? {
        guard let regex = cachedRegex(pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let r = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[r])
    }

}
