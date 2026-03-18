import SwiftUI

// MARK: - CalendarEventQuickActions

/// Static helpers for cross-feature calendar → email actions.
enum CalendarEventQuickActions {

    // MARK: - Email attendees

    /// Opens compose addressed to all non-self attendees of the event.
    @MainActor
    static func emailAttendees(event: CalendarEvent, composeAction: (ComposeMode) -> Void) {
        let recipients = event.attendees
            .filter { !$0.isOrganizer || !event.organizer.map(\.isSelf).defaulted(false) }
            .filter { $0.email != selfEmail(event: event) }
            .map(\.email)

        guard !recipients.isEmpty else { return }

        let to = recipients.joined(separator: ", ")
        let subject = "Re: \(event.summary)"
        composeAction(.reply(
            to: to,
            subject: subject,
            quotedBody: "",
            replyToMessageID: "",
            threadID: ""
        ))
    }

    /// Opens compose addressed to the event organizer only.
    @MainActor
    static func emailOrganizer(event: CalendarEvent, composeAction: (ComposeMode) -> Void) {
        guard let organizer = event.organizer, !organizer.isSelf else { return }
        let subject = "Re: \(event.summary)"
        composeAction(.reply(
            to: organizer.email,
            subject: subject,
            quotedBody: "",
            replyToMessageID: "",
            threadID: ""
        ))
    }

    // MARK: - Share event

    /// Opens compose with formatted event details in the body.
    @MainActor
    static func shareEvent(event: CalendarEvent, composeAction: (ComposeMode) -> Void) {
        let body = eventBody(event: event)
        composeAction(.forward(subject: event.summary, quotedBody: body))
    }

    // MARK: - Schedule from recipients

    /// Passes the email list upstream so a new calendar event editor can be
    /// opened with those addresses pre-filled as attendees.
    @MainActor
    static func scheduleWithRecipients(
        recipients: [String],
        onCreateEvent: ([String]) -> Void
    ) {
        onCreateEvent(recipients)
    }

    // MARK: - Private helpers

    /// Returns the self email derived from the event, or empty string.
    private static func selfEmail(event: CalendarEvent) -> String {
        event.organizer?.isSelf == true ? (event.organizer?.email ?? "") :
        event.attendees.first(where: { _ in
            event.organizer?.isSelf == true
        })?.email ?? ""
    }

    /// Formats an event's details into a human-readable plain-text body.
    private static func eventBody(event: CalendarEvent) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short

        var lines: [String] = [
            "Event: \(event.summary)",
            "When: \(dateFormatter.string(from: event.startTime)) – \(dateFormatter.string(from: event.endTime))",
        ]

        if let location = event.location {
            lines.append("Where: \(location)")
        }

        if let conferenceLink = event.conferenceLink {
            let name = event.conferenceName ?? "Join"
            lines.append("\(name): \(conferenceLink.absoluteString)")
        }

        if let description = event.description, !description.isEmpty {
            lines.append("")
            lines.append(description)
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Optional Bool helper

private extension Optional where Wrapped == Bool {
    func defaulted(_ fallback: Bool) -> Bool { self ?? fallback }
}
