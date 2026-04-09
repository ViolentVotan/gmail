import SwiftUI

// MARK: - CalendarEventEditorViewModel

@Observable @MainActor final class CalendarEventEditorViewModel {

    // MARK: - Form fields

    var summary = ""
    var isAllDay = false
    var startTime = Date()
    var endTime = Date().addingTimeInterval(3600)
    var location = ""
    var eventDescription = ""
    var selectedCalendarID: String = ""
    var attendeeInput = ""
    var attendeeEntries: [AttendeeEntry] = []
    var addGoogleMeet = false
    var reminders: [DraftReminder] = [DraftReminder(method: .popup, minutes: 10)]
    var recurrence: RecurrenceOption = .none
    var colorId: String? = nil
    var visibility: VisibilityOption = .default
    var showAs: ShowAsOption = .busy
    var showRecurringSheet = false
    var showDiscardAlert = false

    // MARK: - Dependencies

    private let calendars: [CalendarInfo]
    let writableCalendars: [CalendarInfo]

    // MARK: - Init

    init(calendars: [CalendarInfo]) {
        self.calendars = calendars
        self.writableCalendars = calendars.filter { $0.accessRole == .writer || $0.accessRole == .owner }
    }

    // MARK: - Derived

    var isEditing: Bool = false

    var hasChanges: Bool = false

    var selectedCalendar: CalendarInfo? {
        writableCalendars.first { $0.calendarId == selectedCalendarID }
    }

    /// Recompute `hasChanges` against the current draft state.
    func updateHasChanges(editDraft: EventEditDraft?) {
        guard let draft = editDraft else {
            hasChanges = !summary.trimmingCharacters(in: .whitespaces).isEmpty
                || !location.isEmpty
                || !eventDescription.isEmpty
                || !attendeeEntries.isEmpty
            return
        }
        hasChanges = summary != draft.summary
            || isAllDay != draft.isAllDay
            || startTime != draft.startTime
            || endTime != draft.endTime
            || location != (draft.location ?? "")
            || eventDescription != (draft.description ?? "")
            || attendeeEntries.map(\.email) != draft.attendeeEmails
            || reminders.map { EventReminder(method: $0.method, minutes: $0.minutes) } != draft.reminders
            || addGoogleMeet != draft.hasConferenceLink
            || colorId != draft.colorId
    }

    // MARK: - Actions

    func handleSave(
        editDraft: EventEditDraft?,
        onSave: (CalendarAPIEventInput, String?, RecurringEditScope?) -> Void
    ) {
        guard !summary.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        if isEditing, let draft = editDraft, draft.isRecurring {
            showRecurringSheet = true
            return
        }

        commitSave(editDraft: editDraft, scope: nil, onSave: onSave)
    }

    func commitSave(
        editDraft: EventEditDraft?,
        scope: RecurringEditScope?,
        onSave: (CalendarAPIEventInput, String?, RecurringEditScope?) -> Void
    ) {
        showRecurringSheet = false

        let startDTO: CalendarAPIDateTime = isAllDay
            ? CalendarAPIDateTime(date: startTime.formattedAllDayISO, dateTime: nil, timeZone: nil)
            : CalendarAPIDateTime(date: nil, dateTime: startTime.rfc3339String, timeZone: TimeZone.current.identifier)

        let endDTO: CalendarAPIDateTime = isAllDay
            ? CalendarAPIDateTime(date: endTime.formattedAllDayISO, dateTime: nil, timeZone: nil)
            : CalendarAPIDateTime(date: nil, dateTime: endTime.rfc3339String, timeZone: TimeZone.current.identifier)

        let attendeeEmails = attendeeEntries.map(\.email)
        let attendeeInputs = attendeeEmails.map { CalendarAPIAttendeeInput(email: $0) }

        let reminderOverrides = reminders.map { r in
            CalendarAPIReminderOverride(method: r.method.rawValue, minutes: r.minutes)
        }

        let currentReminders = reminders.map { EventReminder(method: $0.method, minutes: $0.minutes) }

        let descriptionValue: String? = if let editDraft {
            eventDescription == (editDraft.description ?? "") ? nil : eventDescription
        } else {
            eventDescription.isEmpty ? nil : eventDescription
        }

        let locationValue: String? = if let editDraft {
            location == (editDraft.location ?? "") ? nil : location
        } else {
            location.isEmpty ? nil : location
        }

        let attendeeValue: [CalendarAPIAttendeeInput]? = if let editDraft {
            attendeeEmails == editDraft.attendeeEmails ? nil : attendeeInputs
        } else {
            attendeeInputs.isEmpty ? nil : attendeeInputs
        }

        let reminderValue: CalendarAPIReminders? = if let editDraft {
            currentReminders == editDraft.reminders
                ? nil
                : CalendarAPIReminders(useDefault: false, overrides: reminderOverrides)
        } else {
            CalendarAPIReminders(useDefault: false, overrides: reminderOverrides)
        }

        let conferenceData: CalendarAPIConferenceData? =
            addGoogleMeet && !(editDraft?.hasConferenceLink ?? false)
                ? Self.googleMeetConferenceData()
                : nil

        let input = CalendarAPIEventInput(
            summary: summary,
            description: descriptionValue,
            location: locationValue,
            start: startDTO,
            end: endDTO,
            attendees: attendeeValue,
            reminders: reminderValue,
            conferenceData: conferenceData,
            colorId: colorId,
            recurrence: recurrence.rruleStrings(for: startTime),
            transparency: showAs == .free ? "transparent" : nil,
            visibility: visibility == .default ? nil : visibility.rawValue
        )

        onSave(input, selectedCalendarID.isEmpty ? nil : selectedCalendarID, scope)
    }

    func addAttendee() {
        let trimmed = attendeeInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !attendeeEntries.contains(where: { $0.email == trimmed }) else {
            attendeeInput = ""
            return
        }
        attendeeEntries.append(AttendeeEntry(email: trimmed))
        attendeeInput = ""
    }

    // MARK: - Population

    func populateFromDraft(_ editDraft: EventEditDraft?, defaultStartTime: Date?) {
        isEditing = editDraft != nil

        guard let draft = editDraft else {
            // New event defaults
            if let primary = writableCalendars.first(where: { $0.isPrimary }) {
                selectedCalendarID = primary.calendarId
            } else if let first = writableCalendars.first {
                selectedCalendarID = first.calendarId
            }
            if let defaultStartTime {
                startTime = defaultStartTime
            } else {
                startTime = roundToNextHour(Date())
            }
            endTime = startTime.addingTimeInterval(3600)
            return
        }
        populate(from: draft)
    }

    private func populate(from draft: EventEditDraft) {
        summary = draft.summary
        eventDescription = draft.description ?? ""
        location = draft.location ?? ""
        startTime = draft.startTime
        endTime = draft.endTime
        isAllDay = draft.isAllDay
        attendeeEntries = draft.attendeeEmails.map { AttendeeEntry(email: $0) }
        reminders = draft.reminders.map { DraftReminder(method: $0.method, minutes: $0.minutes) }
        addGoogleMeet = draft.hasConferenceLink
        colorId = draft.colorId
        selectedCalendarID = draft.calendarId
    }

    private static func googleMeetConferenceData() -> CalendarAPIConferenceData {
        CalendarAPIConferenceData(
            createRequest: CalendarAPICreateConferenceRequest(
                requestId: UUID().uuidString,
                conferenceSolutionKey: CalendarAPIConferenceSolutionKey(type: "hangoutsMeet")
            ),
            entryPoints: nil,
            conferenceSolution: nil,
            conferenceId: nil,
            signature: nil,
            notes: nil
        )
    }

    func roundToNextHour(_ date: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        comps.hour = (comps.hour ?? 0) + 1
        comps.minute = 0
        comps.second = 0
        return cal.date(from: comps) ?? date
    }
}

// MARK: - Supporting Types

struct AttendeeEntry: Identifiable {
    let id = UUID()
    var email: String
}

struct DraftReminder: Identifiable {
    let id = UUID()
    var method: EventReminder.ReminderMethod
    var minutes: Int
}

enum RecurrenceOption: String, CaseIterable, Identifiable {
    case none, daily, weekly, monthly, custom
    var id: String { rawValue }

    func label(for date: Date) -> String {
        switch self {
        case .none: return "Does not repeat"
        case .daily: return "Daily"
        case .weekly:
            let dayName = Calendar.current.weekdaySymbols[Calendar.current.component(.weekday, from: date) - 1]
            return "Weekly on \(dayName)"
        case .monthly: return "Monthly"
        case .custom: return "Custom..."
        }
    }

    func rruleStrings(for date: Date) -> [String]? {
        switch self {
        case .none: return nil
        case .daily: return ["RRULE:FREQ=DAILY"]
        case .weekly:
            let days = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
            let idx = Calendar.current.component(.weekday, from: date) - 1
            return ["RRULE:FREQ=WEEKLY;BYDAY=\(days[idx])"]
        case .monthly: return ["RRULE:FREQ=MONTHLY"]
        case .custom: return nil
        }
    }
}

enum VisibilityOption: String, CaseIterable, Identifiable {
    case `default`, `public`, `private`
    var id: String { rawValue }
    var label: String {
        switch self {
        case .default: "Default visibility"
        case .public: "Public"
        case .private: "Private"
        }
    }
}

enum ShowAsOption: String, CaseIterable, Identifiable {
    case busy, free
    var id: String { rawValue }
    var label: String {
        switch self {
        case .busy: "Busy"
        case .free: "Free"
        }
    }
}
