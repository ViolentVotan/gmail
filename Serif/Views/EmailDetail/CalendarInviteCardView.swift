import SwiftUI

struct CalendarInviteCardView: View {
    let invite: CalendarInvite
    let isLoading: Bool
    @Binding var showOriginalEmail: Bool
    var onAccept:  () -> Void
    var onDecline: () -> Void
    var onMaybe:   () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(Typography.subheadSemibold)
                    .foregroundStyle(.tint)
                Text(invite.summary)
                    .font(Typography.subheadSemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            // Date & time
            if !invite.dateText.isEmpty {
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
            if let location = invite.location, !location.isEmpty {
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

            // Organizer
            if let organizer = invite.organizer, !organizer.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text(organizer)
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
                    withAnimation(.easeInOut(duration: 0.2)) { showOriginalEmail.toggle() }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Calendar invite: \(invite.summary)")
    }

    // MARK: - Helpers

    private var hasResponded: Bool {
        invite.rsvpStatus != .pending
    }

    @ViewBuilder
    private func rsvpButton(_ label: String, icon: String, status: CalendarInvite.RSVPStatus, action: @escaping () -> Void) -> some View {
        let isSelected = invite.rsvpStatus == status

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
                    : Color.accentColor.opacity(0.12)
            )
            .foregroundStyle(
                isSelected
                    ? .white
                    : Color.accentColor
            )
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .opacity(hasResponded && !isSelected ? 0.5 : 1)
    }
}
