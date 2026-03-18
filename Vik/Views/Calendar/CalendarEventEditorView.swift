import SwiftUI

// MARK: - RecurringEditScope

enum RecurringEditScope {
    case thisEvent
    case thisAndFollowing
    case allEvents
}

// MARK: - CalendarEventEditorView

struct CalendarEventEditorView: View {
    @Binding var editDraft: EventEditDraft?
    let calendars: [CalendarInfo]
    let onSave: (CalendarAPIEventInput, String?, RecurringEditScope?) -> Void
    let onCancel: () -> Void

    // MARK: - Local state

    @State private var summary = ""
    @State private var isAllDay = false
    @State private var startTime = Date()
    @State private var endTime = Date().addingTimeInterval(3600)
    @State private var location = ""
    @State private var description = ""
    @State private var selectedCalendarID: String = ""
    @State private var attendeeInput = ""
    @State private var attendeeEmails: [String] = []
    @State private var addGoogleMeet = false
    @State private var reminders: [DraftReminder] = [DraftReminder(method: .popup, minutes: 10)]
    @State private var recurrence: RecurrenceOption = .none
    @State private var colorId: String? = nil
    @State private var visibility: VisibilityOption = .default
    @State private var showAs: ShowAsOption = .busy
    @State private var showRecurringSheet = false
    @State private var showDiscardAlert = false

    @FocusState private var isTitleFocused: Bool

    // MARK: - Derived

    private var isEditing: Bool { editDraft != nil }

    private var hasChanges: Bool {
        guard let draft = editDraft else {
            // New event: any non-empty field counts as a change
            return !summary.trimmingCharacters(in: .whitespaces).isEmpty
                || !location.isEmpty
                || !description.isEmpty
                || !attendeeEmails.isEmpty
        }
        return summary != draft.summary
            || isAllDay != draft.isAllDay
            || startTime != draft.startTime
            || endTime != draft.endTime
            || location != (draft.location ?? "")
            || description != (draft.description ?? "")
            || attendeeEmails != draft.attendeeEmails
            || colorId != draft.colorId
    }

    private var writableCalendars: [CalendarInfo] {
        calendars.filter { $0.accessRole == .writer || $0.accessRole == .owner }
    }

    private var selectedCalendar: CalendarInfo? {
        writableCalendars.first { $0.calendarId == selectedCalendarID }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            toolbar

            Divider()
                .opacity(OpacityToken.divider)

            // Form content
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    titleField
                    timingSection
                    locationField
                    descriptionField
                    calendarPicker
                    attendeesSection
                    googleMeetToggle
                    remindersSection
                    recurrenceSection
                    colorPickerSection
                    advancedSection
                }
                .padding(Spacing.lg)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        }
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: CornerRadius.lg))
        .onAppear { populateFromDraft() }
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog(
            "Discard Changes?",
            isPresented: $showDiscardAlert,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { onCancel() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You have unsaved changes.")
        }
        .sheet(isPresented: $showRecurringSheet) {
            recurringEditSheet
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Spacing.sm) {
            Button("Cancel") {
                if hasChanges {
                    showDiscardAlert = true
                } else {
                    onCancel()
                }
            }
            .buttonStyle(.plain)
            .font(Typography.body)
            .foregroundStyle(.secondary)

            Spacer()

            Text(isEditing ? "Edit Event" : "New Event")
                .font(Typography.bodySemibold)
                .foregroundStyle(.primary)

            Spacer()

            Button("Save") {
                handleSave()
            }
            .buttonStyle(.plain)
            .font(Typography.bodySemibold)
            .foregroundStyle(BrandColor.blue)
            .disabled(summary.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    // MARK: - Title Field

    private var titleField: some View {
        TextField("Title", text: $summary)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.primary)
            .textFieldStyle(.plain)
            .focused($isTitleFocused)
            .onAppear { isTitleFocused = true }
    }

    // MARK: - Timing Section

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Toggle("All-day", isOn: $isAllDay)
                .font(Typography.body)
                .toggleStyle(.switch)
                .onChange(of: isAllDay) { _, newValue in
                    if newValue {
                        // Snap times to midnight
                        startTime = Calendar.current.startOfDay(for: startTime)
                        endTime = Calendar.current.startOfDay(for: endTime)
                    }
                }

            if isAllDay {
                DatePicker("Start", selection: $startTime, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .font(Typography.body)
                DatePicker("End", selection: $endTime, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .font(Typography.body)
            } else {
                DatePicker("Start", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .font(Typography.body)
                    .onChange(of: startTime) { _, newStart in
                        if endTime <= newStart {
                            endTime = newStart.addingTimeInterval(3600)
                        }
                    }
                DatePicker("End", selection: $endTime, in: startTime..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .font(Typography.body)
            }
        }
    }

    // MARK: - Location Field

    private var locationField: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "mappin")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            TextField("Location", text: $location)
                .font(Typography.body)
                .textFieldStyle(.plain)
        }
    }

    // MARK: - Description Field

    private var descriptionField: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 4)

            TextEditor(text: $description)
                .font(Typography.body)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Description")
                            .font(Typography.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - Calendar Picker

    private var calendarPicker: some View {
        HStack(spacing: Spacing.sm) {
            if let cal = selectedCalendar {
                Circle()
                    .fill(Color(hex: cal.backgroundColor))
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: "calendar")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }

            Picker("Calendar", selection: $selectedCalendarID) {
                ForEach(writableCalendars) { cal in
                    Text(cal.summaryOverride ?? cal.summary)
                        .tag(cal.calendarId)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Attendees Section

    private var attendeesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                TextField("Add attendees by email", text: $attendeeInput)
                    .font(Typography.body)
                    .textFieldStyle(.plain)
                    .onSubmit { addAttendee() }
            }

            if !attendeeEmails.isEmpty {
                FlowLayout(spacing: Spacing.xs) {
                    ForEach(attendeeEmails, id: \.self) { email in
                        AttendeeChip(email: email) {
                            attendeeEmails.removeAll { $0 == email }
                        }
                    }
                }
                .padding(.leading, 26)
            }
        }
    }

    // MARK: - Google Meet Toggle

    private var googleMeetToggle: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "video")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Toggle("Add Google Meet", isOn: $addGoogleMeet)
                .font(Typography.body)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Reminders Section

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "bell")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("Reminders")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    reminders.append(DraftReminder(method: .popup, minutes: 10))
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(BrandColor.blue)
                }
                .buttonStyle(.plain)
            }

            ForEach($reminders) { $reminder in
                ReminderRow(reminder: $reminder) {
                    reminders.removeAll { $0.id == reminder.id }
                }
                .padding(.leading, 26)
            }
        }
    }

    // MARK: - Recurrence Section

    private var recurrenceSection: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "repeat")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Picker("Recurrence", selection: $recurrence) {
                ForEach(RecurrenceOption.allCases) { option in
                    Text(option.label(for: startTime)).tag(option)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Color Picker Section

    private var colorPickerSection: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "paintpalette")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    // "Default" option (no override)
                    ColorDot(color: .secondary.opacity(0.4), isSelected: colorId == nil) {
                        colorId = nil
                    }
                    ForEach(1...11, id: \.self) { id in
                        ColorDot(
                            color: CalendarColor.color(forId: id),
                            isSelected: colorId == String(id)
                        ) {
                            colorId = String(id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "eye")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Picker("Visibility", selection: $visibility) {
                    ForEach(VisibilityOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
            }

            HStack(spacing: Spacing.sm) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Picker("Show as", selection: $showAs) {
                    ForEach(ShowAsOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - Recurring Edit Sheet

    private var recurringEditSheet: some View {
        VStack(spacing: Spacing.lg) {
            Text("Edit Recurring Event")
                .font(Typography.title)
                .foregroundStyle(.primary)

            VStack(spacing: Spacing.sm) {
                RecurringScopeButton(label: "This event", subtitle: "Only this occurrence") {
                    commitSave(scope: .thisEvent)
                }
                RecurringScopeButton(label: "This and following events", subtitle: "This and all future occurrences") {
                    commitSave(scope: .thisAndFollowing)
                }
                RecurringScopeButton(label: "All events", subtitle: "Every occurrence of this event") {
                    commitSave(scope: .allEvents)
                }
            }

            Button("Cancel") { showRecurringSheet = false }
                .buttonStyle(.plain)
                .font(Typography.body)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.xl)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: CornerRadius.lg))
        .padding(Spacing.xl)
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func handleSave() {
        guard !summary.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        // For recurring edits, show the scope picker first
        if isEditing, let draft = editDraft, draft.isAllDay == isAllDay {
            // Check if the original event was recurring by comparing attendeeEmails presence
            // We use the recurrence picker state as a signal
            if recurrence != .none {
                showRecurringSheet = true
                return
            }
        }

        commitSave(scope: nil)
    }

    private func commitSave(scope: RecurringEditScope?) {
        showRecurringSheet = false

        let allDayFormatter = DateFormatter()
        allDayFormatter.dateFormat = "yyyy-MM-dd"
        allDayFormatter.timeZone = TimeZone.current

        let startDTO: CalendarAPIDateTime = isAllDay
            ? CalendarAPIDateTime(date: allDayFormatter.string(from: startTime), dateTime: nil, timeZone: nil)
            : CalendarAPIDateTime(date: nil, dateTime: CalendarEventService.rfc3339(startTime), timeZone: TimeZone.current.identifier)

        let endDTO: CalendarAPIDateTime = isAllDay
            ? CalendarAPIDateTime(date: allDayFormatter.string(from: endTime), dateTime: nil, timeZone: nil)
            : CalendarAPIDateTime(date: nil, dateTime: CalendarEventService.rfc3339(endTime), timeZone: TimeZone.current.identifier)

        let attendeeInputs = attendeeEmails.map { CalendarAPIAttendeeInput(email: $0) }

        let reminderOverrides = reminders.map { r in
            CalendarAPIReminderOverride(method: r.method.rawValue, minutes: r.minutes)
        }

        let input = CalendarAPIEventInput(
            summary: summary,
            description: description.isEmpty ? nil : description,
            location: location.isEmpty ? nil : location,
            start: startDTO,
            end: endDTO,
            attendees: attendeeInputs.isEmpty ? nil : attendeeInputs,
            reminders: CalendarAPIReminders(useDefault: false, overrides: reminderOverrides),
            conferenceData: nil,
            colorId: colorId,
            recurrence: recurrence.rruleStrings(for: startTime),
            transparency: showAs == .free ? "transparent" : nil,
            visibility: visibility == .default ? nil : visibility.rawValue
        )

        onSave(input, selectedCalendarID.isEmpty ? nil : selectedCalendarID, scope)
    }

    private func addAttendee() {
        let trimmed = attendeeInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !attendeeEmails.contains(trimmed) else {
            attendeeInput = ""
            return
        }
        attendeeEmails.append(trimmed)
        attendeeInput = ""
    }

    // MARK: - Population

    private func populateFromDraft() {
        guard let draft = editDraft else {
            // New event defaults
            if let primary = writableCalendars.first(where: { $0.isPrimary }) {
                selectedCalendarID = primary.calendarId
            } else if let first = writableCalendars.first {
                selectedCalendarID = first.calendarId
            }
            startTime = roundToNextHour(Date())
            endTime = startTime.addingTimeInterval(3600)
            return
        }
        populate(from: draft)
    }

    private func populate(from draft: EventEditDraft) {
        summary = draft.summary
        description = draft.description ?? ""
        location = draft.location ?? ""
        startTime = draft.startTime
        endTime = draft.endTime
        isAllDay = draft.isAllDay
        attendeeEmails = draft.attendeeEmails
        colorId = draft.colorId
    }

    private func roundToNextHour(_ date: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        comps.hour = (comps.hour ?? 0) + 1
        comps.minute = 0
        comps.second = 0
        return cal.date(from: comps) ?? date
    }
}

// MARK: - Supporting Types

private struct DraftReminder: Identifiable {
    let id = UUID()
    var method: EventReminder.ReminderMethod
    var minutes: Int
}

private enum RecurrenceOption: String, CaseIterable, Identifiable {
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

private enum VisibilityOption: String, CaseIterable, Identifiable {
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

private enum ShowAsOption: String, CaseIterable, Identifiable {
    case busy, free
    var id: String { rawValue }
    var label: String {
        switch self {
        case .busy: "Busy"
        case .free: "Free"
        }
    }
}

// MARK: - ReminderRow

private struct ReminderRow: View {
    @Binding var reminder: DraftReminder
    let onRemove: () -> Void

    @State private var minutesText: String = ""

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Picker("Method", selection: $reminder.method) {
                Text("Notification").tag(EventReminder.ReminderMethod.popup)
                Text("Email").tag(EventReminder.ReminderMethod.email)
            }
            .labelsHidden()
            .frame(width: 120)

            TextField("Minutes", text: $minutesText)
                .font(Typography.body)
                .textFieldStyle(.plain)
                .frame(width: 50)
                .multilineTextAlignment(.trailing)
                .onAppear { minutesText = String(reminder.minutes) }
                .onChange(of: minutesText) { _, val in
                    if let n = Int(val) { reminder.minutes = n }
                }

            Text("min before")
                .font(Typography.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(SemanticColor.error)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - AttendeeChip

private struct AttendeeChip: View {
    let email: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(email)
                .font(Typography.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(OpacityToken.tag))
        .clipShape(.rect(cornerRadius: CornerRadius.sm))
    }
}

// MARK: - ColorDot

private struct ColorDot: View {
    let color: Color
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(.white, lineWidth: 2)
                            .padding(2)
                    }
                }
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(color, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - RecurringScopeButton

private struct RecurringScopeButton: View {
    let label: String
    let subtitle: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(Typography.bodySemibold)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(isHovered ? Color.primary.opacity(OpacityToken.tag) : Color.clear)
            .clipShape(.rect(cornerRadius: CornerRadius.md))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - FlowLayout

/// Simple flow layout for attendee chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                totalHeight += lineHeight + spacing
                currentX = 0
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentY += lineHeight + spacing
                currentX = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Preview

#Preview("New Event") {
    @Previewable @State var draft: EventEditDraft? = nil
    let calendars = [
        CalendarInfo(
            calendarId: "primary",
            accountID: "user@example.com",
            summary: "My Calendar",
            description: nil,
            timeZone: "America/New_York",
            backgroundColor: "#4285F4",
            foregroundColor: "#FFFFFF",
            isPrimary: true,
            accessRole: .owner,
            isVisible: true,
            summaryOverride: nil
        )
    ]
    CalendarEventEditorView(
        editDraft: $draft,
        calendars: calendars,
        onSave: { _, _, _ in },
        onCancel: {}
    )
    .frame(width: 420, height: 640)
}

#Preview("Edit Event") {
    @Previewable @State var draft: EventEditDraft? = {
        let event = CalendarEvent(
            googleEventId: "edit-1",
            calendarId: "primary",
            accountID: "user@example.com",
            summary: "Team Standup",
            description: "Daily sync",
            location: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800),
            isAllDay: false,
            timeZone: nil,
            status: .confirmed,
            organizer: nil,
            creator: nil,
            attendees: [],
            selfResponseStatus: .accepted,
            conferenceLink: nil,
            conferenceName: nil,
            colorId: "9",
            resolvedColor: CalendarColor.blueberry,
            isRecurring: true,
            recurringEventId: "recur-1",
            reminders: [],
            eventType: .default,
            etag: "etag",
            htmlLink: nil,
            canEdit: true,
            attachments: []
        )
        return EventEditDraft(from: event)
    }()
    let previewCalendars = [
        CalendarInfo(
            calendarId: "primary",
            accountID: "user@example.com",
            summary: "My Calendar",
            description: nil,
            timeZone: "America/New_York",
            backgroundColor: "#4285F4",
            foregroundColor: "#FFFFFF",
            isPrimary: true,
            accessRole: .owner,
            isVisible: true,
            summaryOverride: nil
        )
    ]
    CalendarEventEditorView(
        editDraft: $draft,
        calendars: previewCalendars,
        onSave: { _, _, _ in },
        onCancel: {}
    )
    .frame(width: 420, height: 640)
}
