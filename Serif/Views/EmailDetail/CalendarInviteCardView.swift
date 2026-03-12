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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(invite.summary)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            // Date & time
            if !invite.dateText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text(invite.dateText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            // Location
            if let location = invite.location, !location.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text(location)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            // Organizer
            if let organizer = invite.organizer, !organizer.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    Text(organizer)
                        .font(.system(size: 13))
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
                            .font(.system(size: 9, weight: .medium))
                        Text(showOriginalEmail ? "Hide original" : "Show original")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separatorColor), lineWidth: 1)
        )
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
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                isSelected
                    ? Color.accentColor
                    : Color.accentColor.opacity(0.12)
            )
            .foregroundColor(
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
