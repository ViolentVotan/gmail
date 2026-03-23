import SwiftUI

struct CalendarInviteCardView: View {
    let invite: CalendarInvite
    let isLoading: Bool
    @Binding var showOriginalEmail: Bool
    var calendarEvent: CalendarEvent?
    var onAccept:  () -> Void
    var onDecline: () -> Void
    var onMaybe:   () -> Void

    // MARK: - Derived

    /// Display title: prefer real event data when available.
    private var displaySummary: String {
        calendarEvent?.summary ?? invite.summary
    }

    /// Display organizer: prefer organizer display name from calendar event.
    private var displayOrganizer: String? {
        if let event = calendarEvent {
            return event.organizer?.displayName ?? event.organizer?.email
        }
        return invite.organizer
    }

    /// Display location: prefer event location.
    private var displayLocation: String? {
        calendarEvent?.location ?? invite.location
    }

    /// Attendee count from real event data.
    private var attendeeCount: Int? {
        guard let event = calendarEvent, !event.attendees.isEmpty else { return nil }
        return event.attendees.count
    }

    /// Conference link from real event data.
    private var conferenceURL: URL? {
        calendarEvent?.conferenceLink
    }

    /// Current RSVP status, preferring real event data.
    private var currentStatus: CalendarInvite.RSVPStatus {
        guard let event = calendarEvent else { return invite.rsvpStatus }
        return switch event.selfResponseStatus {
        case .accepted:    .accepted
        case .declined:    .declined
        case .tentative:   .maybe
        case .needsAction: .pending
        }
    }

    private var hasResponded: Bool {
        currentStatus != .pending
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Title
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(Typography.subheadSemibold)
                    .foregroundStyle(.tint)
                Text(displaySummary)
                    .font(Typography.subheadSemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            // Date & time (from invite HTML parse; real event uses startTime/endTime)
            if let event = calendarEvent {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text(event.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                }
            } else if !invite.dateText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text(invite.dateText)
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                }
            }

            // Location
            if let location = displayLocation, !location.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text(location)
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            // Conference link (only when real event data available)
            if let url = conferenceURL, let name = calendarEvent?.conferenceName {
                Link(destination: url) {
                    HStack(spacing: 8) {
                        Image(systemName: "video")
                            .font(Typography.subheadRegular)
                            .foregroundStyle(.tertiary)
                            .frame(width: 16)
                        Text(name)
                            .font(Typography.body)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }

            // Organizer + attendee count
            HStack(spacing: 8) {
                Image(systemName: "person")
                    .font(Typography.subheadRegular)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                if let organizer = displayOrganizer, !organizer.isEmpty {
                    Text(organizer)
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let count = attendeeCount {
                    Text("· \(count) attendee\(count == 1 ? "" : "s")")
                        .font(Typography.body)
                        .foregroundStyle(.tertiary)
                }
            }

            Divider().background(Color(.separatorColor))

            // RSVP buttons + show original
            HStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    HStack(spacing: 10) {
                        rsvpButton("Accept", icon: "checkmark", status: .accepted, action: onAccept)
                        rsvpButton("Decline", icon: "xmark", status: .declined, action: onDecline)
                        rsvpButton("Maybe", icon: "questionmark", status: .maybe, action: onMaybe)
                    }
                }

                Spacer()

                Button {
                    withAnimation(VikAnimation.springSnappy) { showOriginalEmail.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showOriginalEmail ? "chevron.up" : "chevron.down")
                            .font(Typography.captionSmallMedium)
                        Text(showOriginalEmail ? "Hide original" : "Show original")
                            .font(Typography.caption)
                    }
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar invite: \(displaySummary)")
    }

    // MARK: - Helpers

    @ViewBuilder
    private func rsvpButton(_ label: String, icon: String, status: CalendarInvite.RSVPStatus, action: @escaping () -> Void) -> some View {
        let isSelected = currentStatus == status

        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "checkmark" : icon)
                    .font(Typography.caption)
                Text(label)
                    .font(Typography.subhead)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                isSelected
                    ? Color.accentColor
                    : Color.accentColor.opacity(OpacityToken.tag)
            )
            .foregroundStyle(
                isSelected
                    ? .white
                    : Color.accentColor
            )
            .clipShape(.rect(cornerRadius: CornerRadius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .opacity(hasResponded && !isSelected ? 0.5 : 1)
    }
}
