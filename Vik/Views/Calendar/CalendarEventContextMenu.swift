import SwiftUI

/// Shared context menu for calendar event cards — used across week, day, and agenda views.
struct CalendarEventContextMenu: View {
    let event: CalendarEvent
    var onEdit: ((CalendarEvent) -> Void)?
    var onDelete: ((CalendarEvent) -> Void)?
    var onRSVP: ((CalendarEvent, CalendarRSVPStatus) -> Void)?
    var onEmailAttendees: ((CalendarEvent) -> Void)?

    private var isOrganizer: Bool {
        event.organizer?.isSelf == true
    }

    var body: some View {
        // RSVP submenu — only if user is not the organizer
        if !isOrganizer {
            Menu {
                Button {
                    onRSVP?(event, .accepted)
                } label: {
                    Label("Accept", systemImage: "checkmark")
                }
                Button {
                    onRSVP?(event, .tentative)
                } label: {
                    Label("Maybe", systemImage: "questionmark")
                }
                Button {
                    onRSVP?(event, .declined)
                } label: {
                    Label("Decline", systemImage: "xmark")
                }
            } label: {
                Label("RSVP", systemImage: "person.crop.circle.badge.checkmark")
            }
        }

        if event.canEdit {
            Button {
                onEdit?(event)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }

        Button(role: .destructive) {
            onDelete?(event)
        } label: {
            Label("Delete", systemImage: "trash")
        }

        Divider()

        if !event.attendees.isEmpty {
            Button {
                onEmailAttendees?(event)
            } label: {
                Label("Email Attendees", systemImage: "envelope")
            }
        }

        if let htmlLink = event.htmlLink {
            Button {
                NSWorkspace.shared.open(htmlLink)
            } label: {
                Label("Open in Google Calendar", systemImage: "safari")
            }
        }
    }
}
