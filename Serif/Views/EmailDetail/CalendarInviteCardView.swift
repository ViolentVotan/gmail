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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(invite.summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            // Date & time
            if !invite.dateText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text(invite.dateText)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            // Location
            if let location = invite.location, !location.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text(location)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            // Organizer
            if let organizer = invite.organizer, !organizer.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text(organizer)
                        .font(.body)
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
                            .font(.caption2.weight(.medium))
                        Text(showOriginalEmail ? "Hide original" : "Show original")
                            .font(.caption.weight(.medium))
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
                    .font(.caption.weight(.medium))
                Text(label)
                    .font(.subheadline.weight(.medium))
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
