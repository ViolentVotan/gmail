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
    var defaultStartTime: Date? = nil
    let onSave: (CalendarAPIEventInput, String?, RecurringEditScope?) -> Void
    let onCancel: () -> Void

    @State private var viewModel: CalendarEventEditorViewModel
    @State private var saveHapticTrigger = false
    @FocusState private var isTitleFocused: Bool

    init(
        editDraft: Binding<EventEditDraft?>,
        calendars: [CalendarInfo],
        defaultStartTime: Date? = nil,
        onSave: @escaping (CalendarAPIEventInput, String?, RecurringEditScope?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._editDraft = editDraft
        self.calendars = calendars
        self.defaultStartTime = defaultStartTime
        self.onSave = onSave
        self.onCancel = onCancel
        self._viewModel = State(initialValue: CalendarEventEditorViewModel(calendars: calendars))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            toolbar

            Divider()

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
        .task {
            viewModel.populateFromDraft(editDraft, defaultStartTime: defaultStartTime)
            viewModel.updateHasChanges(editDraft: editDraft)
            isTitleFocused = true
        }
        .sensoryFeedback(.success, trigger: saveHapticTrigger)
        .interactiveDismissDisabled(viewModel.hasChanges)
        .confirmationDialog(
            "Discard Changes?",
            isPresented: $viewModel.showDiscardAlert,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { onCancel() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You have unsaved changes.")
        }
        .sheet(isPresented: $viewModel.showRecurringSheet) {
            recurringEditSheet
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Spacing.sm) {
            Button("Cancel") {
                if viewModel.hasChanges {
                    viewModel.showDiscardAlert = true
                } else {
                    onCancel()
                }
            }
            .keyboardShortcut(.escape)
            .buttonStyle(.glass)
            .font(Typography.body)
            .foregroundStyle(.secondary)

            Spacer()

            Text(viewModel.isEditing ? "Edit Event" : "New Event")
                .font(Typography.bodySemibold)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button("Save") {
                saveHapticTrigger.toggle()
                viewModel.handleSave(editDraft: editDraft, onSave: onSave)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.glass)
            .font(Typography.bodySemibold)
            .foregroundStyle(BrandColor.blueText)
            .disabled(viewModel.summary.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    // MARK: - Title Field

    private var titleField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            TextField("Title", text: $viewModel.summary)
                .font(Typography.calendarEditorTitle)
                .foregroundStyle(.primary)
                .textFieldStyle(.plain)
                .focused($isTitleFocused)
                .onChange(of: viewModel.summary) { _, _ in viewModel.updateHasChanges(editDraft: editDraft) }
            Text("*")
                .font(Typography.calendarEditorTitle)
                .foregroundStyle(SemanticColor.error)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Timing Section

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Toggle("All-day", isOn: $viewModel.isAllDay)
                .font(Typography.body)
                .toggleStyle(.switch)
                .onChange(of: viewModel.isAllDay) { _, newValue in
                    if newValue {
                        viewModel.startTime = Calendar.current.startOfDay(for: viewModel.startTime)
                        viewModel.endTime = Calendar.current.startOfDay(for: viewModel.endTime)
                    }
                    viewModel.updateHasChanges(editDraft: editDraft)
                }

            if viewModel.isAllDay {
                DatePicker("Start", selection: $viewModel.startTime, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .font(Typography.body)
                    .onChange(of: viewModel.startTime) { _, _ in viewModel.updateHasChanges(editDraft: editDraft) }
                DatePicker("End", selection: $viewModel.endTime, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .font(Typography.body)
                    .onChange(of: viewModel.endTime) { _, _ in viewModel.updateHasChanges(editDraft: editDraft) }
            } else {
                DatePicker("Start", selection: $viewModel.startTime, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .font(Typography.body)
                    .onChange(of: viewModel.startTime) { _, newStart in
                        if viewModel.endTime <= newStart {
                            viewModel.endTime = newStart.addingTimeInterval(3600)
                        }
                        viewModel.updateHasChanges(editDraft: editDraft)
                    }
                DatePicker("End", selection: $viewModel.endTime, in: viewModel.startTime..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .font(Typography.body)
                    .onChange(of: viewModel.endTime) { _, _ in viewModel.updateHasChanges(editDraft: editDraft) }
            }
        }
    }

    // MARK: - Location Field

    private var locationField: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "mappin")
                .font(.system(size: CalendarLayout.editorIconSize))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            TextField("Location", text: $viewModel.location)
                .font(Typography.body)
                .textFieldStyle(.plain)
                .textContentType(.location)
                .accessibilityLabel("Location")
                .onChange(of: viewModel.location) { _, _ in viewModel.updateHasChanges(editDraft: editDraft) }
        }
    }

    // MARK: - Description Field

    private var descriptionField: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "text.alignleft")
                .font(.system(size: CalendarLayout.editorIconSize))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, Spacing.xs)

            TextEditor(text: $viewModel.eventDescription)
                .font(Typography.body)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Description")
                .overlay(alignment: .topLeading) {
                    if viewModel.eventDescription.isEmpty {
                        Text("Description")
                            .font(Typography.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, Spacing.xs)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: viewModel.eventDescription) { _, _ in viewModel.updateHasChanges(editDraft: editDraft) }
        }
    }

    // MARK: - Calendar Picker

    private var calendarPicker: some View {
        HStack(spacing: Spacing.sm) {
            if let cal = viewModel.selectedCalendar {
                Circle()
                    .fill(Color(hex: cal.backgroundColor))
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: "calendar")
                    .font(.system(size: CalendarLayout.editorIconSize))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }

            Picker("Calendar", selection: $viewModel.selectedCalendarID) {
                ForEach(viewModel.writableCalendars) { cal in
                    Text(cal.summaryOverride ?? cal.summary)
                        .tag(cal.calendarId)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Calendar")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Attendees Section

    private var attendeesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: CalendarLayout.editorIconSize))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                TextField("Add attendees by email", text: $viewModel.attendeeInput)
                    .font(Typography.body)
                    .textFieldStyle(.plain)
                    .textContentType(.emailAddress)
                    .onSubmit {
                        viewModel.addAttendee()
                        viewModel.updateHasChanges(editDraft: editDraft)
                    }
            }

            if !viewModel.attendeeEntries.isEmpty {
                FlowLayout(spacing: Spacing.xs) {
                    ForEach(viewModel.attendeeEntries) { entry in
                        AttendeeChip(email: entry.email) {
                            viewModel.attendeeEntries.removeAll { $0.id == entry.id }
                            viewModel.updateHasChanges(editDraft: editDraft)
                        }
                    }
                }
                .padding(.leading, Spacing.xl + Spacing.xxs)
            }
        }
    }

    // MARK: - Google Meet Toggle

    private var googleMeetToggle: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "video")
                .font(.system(size: CalendarLayout.editorIconSize))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Toggle("Add Google Meet", isOn: $viewModel.addGoogleMeet)
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
                        .font(.system(size: CalendarLayout.editorIconSize))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("Reminders")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.reminders.append(DraftReminder(method: .popup, minutes: 10))
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: CalendarLayout.editorActionIconSize))
                        .foregroundStyle(BrandColor.blueText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add reminder")
                .accessibilityLabel("Add reminder")
            }

            ForEach($viewModel.reminders) { $reminder in
                ReminderRow(reminder: $reminder) {
                    viewModel.reminders.removeAll { $0.id == reminder.id }
                }
                .padding(.leading, Spacing.xl + Spacing.xxs)
            }
        }
    }

    // MARK: - Recurrence Section

    private var recurrenceSection: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "repeat")
                .font(.system(size: CalendarLayout.editorIconSize))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Picker("Recurrence", selection: $viewModel.recurrence) {
                ForEach(RecurrenceOption.allCases) { option in
                    Text(option.label(for: viewModel.startTime)).tag(option)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Recurrence")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Color Picker Section

    private var colorPickerSection: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "paintpalette")
                .font(.system(size: CalendarLayout.editorIconSize))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ColorDot(color: .secondary.opacity(0.4), isSelected: viewModel.colorId == nil, colorName: "Calendar default") {
                        viewModel.colorId = nil
                        viewModel.updateHasChanges(editDraft: editDraft)
                    }
                    ForEach(1...11, id: \.self) { id in
                        ColorDot(
                            color: CalendarColor.color(forId: id),
                            isSelected: viewModel.colorId == String(id),
                            colorName: CalendarColor.name(forId: id)
                        ) {
                            viewModel.colorId = String(id)
                            viewModel.updateHasChanges(editDraft: editDraft)
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
                    .font(.system(size: CalendarLayout.editorIconSize))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Picker("Visibility", selection: $viewModel.visibility) {
                    ForEach(VisibilityOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Visibility")
            }

            HStack(spacing: Spacing.sm) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: CalendarLayout.editorIconSize))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Picker("Show as", selection: $viewModel.showAs) {
                    ForEach(ShowAsOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Show as")
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
                    viewModel.commitSave(scope: .thisEvent, onSave: onSave)
                }
                RecurringScopeButton(label: "This and following events", subtitle: "This and all future occurrences") {
                    viewModel.commitSave(scope: .thisAndFollowing, onSave: onSave)
                }
                RecurringScopeButton(label: "All events", subtitle: "Every occurrence of this event") {
                    viewModel.commitSave(scope: .allEvents, onSave: onSave)
                }
            }

            Button("Cancel") { viewModel.showRecurringSheet = false }
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
}

// MARK: - Supporting View Types

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
                .accessibilityLabel("Minutes before event")
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
                    .font(.system(size: CalendarLayout.editorActionIconSize))
                    .foregroundStyle(SemanticColor.error)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove reminder")
            .accessibilityLabel("Remove reminder")
        }
    }
}

// MARK: - AttendeeChip

private struct AttendeeChip: View {
    let email: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(email)
                .font(Typography.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: CalendarLayout.editorSmallIconSize))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(email)")
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(Color.secondary.opacity(OpacityToken.tag))
        .clipShape(.rect(cornerRadius: CornerRadius.sm))
    }
}

// MARK: - ColorDot

private struct ColorDot: View {
    let color: Color
    let isSelected: Bool
    let colorName: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                            .padding(Spacing.xxs)
                    }
                }
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(color, lineWidth: 2)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Event color: \(colorName)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
                    .font(.system(size: CalendarLayout.editorChevronSize, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .glassEffect(isHovered ? .regular.interactive() : .identity, in: .rect(cornerRadius: CornerRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(subtitle)")
        .help(label)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview("New Event") {
    @Previewable @State var draft: EventEditDraft? = nil
    let calendars = [
        CalendarInfo(
            id: "user@example.com_primary",
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
            id: "user@example.com_primary_edit-1",
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
            id: "user@example.com_primary",
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
