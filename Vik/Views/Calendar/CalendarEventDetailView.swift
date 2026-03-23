import SwiftUI

// MARK: - CalendarEventDetailView

struct CalendarEventDetailView: View {
    let event: CalendarEvent
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onRSVP: (CalendarRSVPStatus) -> Void
    let onEmailAttendees: () -> Void
    let onDismiss: () -> Void
    var composeTo: ((String) -> Void)?
    var searchSender: ((String) -> Void)?

    @State private var isHoveringLocation = false
    @State private var isHoveringConference = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Header
            headerSection

            Divider()
                .opacity(OpacityToken.divider)

            // MARK: Scrollable body
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    timeSection
                    if event.location != nil { locationSection }
                    if event.conferenceLink != nil { conferenceSection }
                    if event.organizer != nil { organizerSection }
                    if !event.attendees.isEmpty { attendeesSection }
                    if event.description != nil { descriptionSection }
                    if !event.reminders.isEmpty { remindersSection }
                }
                .padding(Spacing.lg)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)

            Divider()
                .opacity(OpacityToken.divider)

            // MARK: Actions bar
            actionsBar
        }
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: CornerRadius.lg))
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: Spacing.sm) {
            Circle()
                .fill(event.resolvedColor)
                .frame(width: 10, height: 10)

            Text(event.summary)
                .font(Typography.calendarDetailTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: CalendarLayout.detailCloseIconSize))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    // MARK: - Time

    private var timeSection: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "clock")
                .font(.system(size: CalendarLayout.editorIconSize))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                if event.isAllDay {
                    Text(fullDateString(event.startTime))
                        .font(Typography.body)
                        .foregroundStyle(.primary)
                } else {
                    Text(dateRangeString)
                        .font(Typography.body)
                        .foregroundStyle(.primary)
                    Text(event.formattedTimeRange)
                        .font(Typography.callout)
                        .foregroundStyle(.secondary)
                }

                if let tz = event.timeZone,
                   tz != TimeZone.current.identifier {
                    Text(tz)
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }

                if event.isRecurring {
                    HStack(spacing: 4) {
                        Image(systemName: "repeat")
                            .font(.system(size: CalendarLayout.detailSmallIconSize))
                        Text("Recurring event")
                            .font(Typography.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Location

    private var locationSection: some View {
        Button {
            guard let location = event.location,
                  let encoded = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "maps://?q=\(encoded)") else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "mappin")
                    .font(.system(size: CalendarLayout.editorIconSize))
                    .foregroundStyle(BrandColor.blueText)
                    .frame(width: 18)
                    .padding(.top, 2)

                Text(event.location ?? "")
                    .font(Typography.body)
                    .foregroundStyle(BrandColor.blueText)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open location: \(event.location ?? "")")
        .accessibilityHint("Opens in Maps")
        .scaleEffect(isHoveringLocation ? ScaleToken.hover : 1.0)
        .animation(reduceMotion ? nil : VikAnimation.springDefault, value: isHoveringLocation)
        .onHover { isHoveringLocation = $0 }
    }

    // MARK: - Conference

    private var conferenceSection: some View {
        Button {
            guard let url = event.conferenceLink else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "video.fill")
                    .font(.system(size: CalendarLayout.detailMeetingIconSize))
                Text(event.conferenceName ?? "Join Meeting")
                    .font(Typography.bodySemibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(BrandColor.blue)
            .clipShape(.rect(cornerRadius: CornerRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Join meeting")
        .accessibilityHint("Opens in browser")
        .scaleEffect(isHoveringConference ? ScaleToken.hover : 1.0)
        .animation(reduceMotion ? nil : VikAnimation.springDefault, value: isHoveringConference)
        .onHover { isHoveringConference = $0 }
    }

    // MARK: - Organizer

    private var organizerSection: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "person.circle")
                .font(.system(size: CalendarLayout.editorIconSize))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("Organizer")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                if let organizer = event.organizer {
                    VStack(alignment: .leading, spacing: 2) {
                        if let name = organizer.displayName {
                            Text(name)
                                .font(Typography.callout)
                                .foregroundStyle(.primary)
                        }
                        Text(organizer.email)
                            .font(Typography.calendarAgendaTime)
                            .foregroundStyle(.secondary)
                    }
                    .contactPopover(
                        contact: Contact(name: organizer.displayName ?? organizer.email, email: organizer.email),
                        accountID: event.accountID,
                        composeTo: { composeTo?($0) },
                        searchSender: { searchSender?($0) }
                    )
                }
            }
        }
    }

    // MARK: - Attendees

    private var attendeesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "person.2")
                    .font(.system(size: CalendarLayout.editorIconSize))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Attendees (\(event.attendees.count))")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(event.attendees) { attendee in
                    AttendeeRowView(
                        attendee: attendee,
                        accountID: event.accountID,
                        composeTo: composeTo,
                        searchSender: searchSender
                    )
                }
            }
            .padding(.leading, 26)
        }
    }

    // MARK: - Description

    private var descriptionSection: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "text.alignleft")
                .font(.system(size: CalendarLayout.editorIconSize))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)

            Text(event.description ?? "")
                .font(Typography.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "bell")
                .font(.system(size: CalendarLayout.editorIconSize))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(event.reminders.indices, id: \.self) { idx in
                    let reminder = event.reminders[idx]
                    Text(reminderLabel(reminder))
                        .font(Typography.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions Bar

    private var actionsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                // RSVP buttons — only if user is not the organizer
                if !isOrganizer {
                    rsvpButton(.accepted, icon: "checkmark", label: "Accept")
                    rsvpButton(.tentative, icon: "questionmark", label: "Maybe")
                    rsvpButton(.declined, icon: "xmark", label: "Decline")
                    Divider()
                        .frame(height: 20)
                        .padding(.horizontal, 2)
                }

                if event.canEdit {
                    ActionBarButton(icon: "pencil", label: "Edit", action: onEdit)
                }

                ActionBarButton(icon: "trash", label: "Delete", isDestructive: true, action: onDelete)

                if !event.attendees.isEmpty {
                    ActionBarButton(icon: "envelope", label: "Email Attendees", action: onEmailAttendees)
                }

                if let htmlLink = event.htmlLink {
                    ActionBarButton(icon: "safari", label: "Open in Calendar") {
                        NSWorkspace.shared.open(htmlLink)
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
        }
    }

    // MARK: - Private Helpers

    private var isOrganizer: Bool {
        event.organizer?.isSelf == true
    }

    private var dateRangeString: String {
        let start = event.startTime.formattedFullDate
        let end = event.endTime.formattedFullDate
        return start == end ? start : "\(start) – \(end)"
    }

    private func fullDateString(_ date: Date) -> String {
        date.formattedFullDate
    }

    private func reminderLabel(_ reminder: EventReminder) -> String {
        let methodLabel = reminder.method == .email ? "Email" : "Notification"
        let mins = reminder.minutes
        if mins == 0 { return "\(methodLabel) at event time" }
        if mins < 60 { return "\(methodLabel) \(mins) min before" }
        let hours = mins / 60
        let remaining = mins % 60
        if remaining == 0 { return "\(methodLabel) \(hours) hr before" }
        return "\(methodLabel) \(hours) hr \(remaining) min before"
    }

    @ViewBuilder
    private func rsvpButton(_ status: CalendarRSVPStatus, icon: String, label: String) -> some View {
        let isCurrent = event.selfResponseStatus == status
        Button {
            onRSVP(status)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(Typography.calendarEventTitle)
                Text(label)
                    .font(Typography.captionSemibold)
            }
            .foregroundStyle(isCurrent ? .white : .primary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(isCurrent ? rsvpColor(status) : Color.primary.opacity(OpacityToken.tag))
            .clipShape(.rect(cornerRadius: CornerRadius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private func rsvpColor(_ status: CalendarRSVPStatus) -> Color {
        switch status {
        case .accepted: SemanticColor.success
        case .declined: SemanticColor.error
        case .tentative: Color.secondary
        case .needsAction: Color.secondary
        }
    }
}

// MARK: - AttendeeRowView

private struct AttendeeRowView: View {
    let attendee: EventAttendee
    var accountID: String = ""
    var composeTo: ((String) -> Void)?
    var searchSender: ((String) -> Void)?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Response status badge
            Image(systemName: statusIcon)
                .font(Typography.calendarEventTitle)
                .foregroundStyle(statusColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                if let name = attendee.displayName {
                    Text(name)
                        .font(Typography.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(attendee.email)
                    .font(Typography.calendarMiniEventTime)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contactPopover(
                contact: Contact(name: attendee.displayName ?? attendee.email, email: attendee.email),
                accountID: accountID,
                composeTo: { composeTo?($0) },
                searchSender: { searchSender?($0) }
            )

            if attendee.isOrganizer {
                Text("Organizer")
                    .font(Typography.microTag)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(OpacityToken.tag))
                    .clipShape(.rect(cornerRadius: CornerRadius.xs))
            }

            if attendee.isOptional {
                Text("Optional")
                    .font(Typography.microTag)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(OpacityToken.tag))
                    .clipShape(.rect(cornerRadius: CornerRadius.xs))
            }

            Spacer(minLength: 0)
        }
    }

    private var statusIcon: String {
        switch attendee.responseStatus {
        case .accepted: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .needsAction: "circle"
        }
    }

    private var statusColor: Color {
        switch attendee.responseStatus {
        case .accepted: SemanticColor.success
        case .declined: SemanticColor.error
        case .tentative: Color.secondary
        case .needsAction: Color.secondary
        }
    }
}

// MARK: - ActionBarButton

private struct ActionBarButton: View {
    let icon: String
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(Typography.calendarAgendaTime)
                Text(label)
                    .font(Typography.caption)
            }
            .foregroundStyle(isDestructive ? SemanticColor.error : Color.primary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .glassEffect(isHovered ? .regular.interactive() : .identity, in: .rect(cornerRadius: CornerRadius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .scaleEffect(isHovered ? ScaleToken.hover : 1.0)
        .animation(reduceMotion ? nil : VikAnimation.springDefault, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview {
    let event = CalendarEvent(
        id: "user@example.com_primary_preview-1",
        googleEventId: "preview-1",
        calendarId: "primary",
        accountID: "user@example.com",
        summary: "Q1 Planning Session",
        description: "Quarterly planning meeting to review OKRs and set goals for the upcoming quarter.",
        location: "1600 Amphitheatre Pkwy, Mountain View, CA",
        startTime: Date(),
        endTime: Date().addingTimeInterval(5400),
        isAllDay: false,
        timeZone: nil,
        status: .confirmed,
        organizer: EventPerson(email: "organizer@example.com", displayName: "Jane Smith", isSelf: false),
        creator: nil,
        attendees: [
            EventAttendee(email: "alice@example.com", displayName: "Alice", responseStatus: .accepted, isOrganizer: false, isResource: false, isOptional: false),
            EventAttendee(email: "bob@example.com", displayName: "Bob", responseStatus: .declined, isOrganizer: false, isResource: false, isOptional: true),
            EventAttendee(email: "carol@example.com", displayName: nil, responseStatus: .tentative, isOrganizer: false, isResource: false, isOptional: false)
        ],
        selfResponseStatus: .needsAction,
        conferenceLink: URL(string: "https://meet.google.com/abc-defg-hij"),
        conferenceName: "Google Meet",
        colorId: "9",
        resolvedColor: CalendarColor.blueberry,
        isRecurring: true,
        recurringEventId: "recur-1",
        reminders: [
            EventReminder(method: .popup, minutes: 10),
            EventReminder(method: .email, minutes: 60)
        ],
        eventType: .default,
        etag: "etag-123",
        htmlLink: URL(string: "https://calendar.google.com/calendar/event?eid=xxx"),
        canEdit: true,
        attachments: []
    )
    CalendarEventDetailView(
        event: event,
        onEdit: {},
        onDelete: {},
        onRSVP: { _ in },
        onEmailAttendees: {},
        onDismiss: {}
    )
    .frame(width: 360, height: 600)
}
