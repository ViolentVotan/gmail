import SwiftUI

struct CalendarContainer: View {
    let coordinator: AppCoordinator
    let calendarVM: CalendarViewModel
    @Binding var showNewCalendarEvent: Bool
    @Binding var newCalendarEventDraft: EventEditDraft?
    @Binding var newEventStartTime: Date?

    var body: some View {
        CalendarContainerView(
            viewModel: calendarVM,
            onNewEvent: {
                newCalendarEventDraft = nil
                newEventStartTime = nil
                showNewCalendarEvent = true
            },
            onSelectEvent: { event in
                calendarVM.selectedEvent = event
            },
            onCreateEvent: { date, hour in
                calendarVM.selectedDate = date
                newCalendarEventDraft = nil
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
                comps.hour = hour
                newEventStartTime = Calendar.current.date(from: comps)
                showNewCalendarEvent = true
            },
            onEdit: { event in
                calendarVM.selectedEvent = nil
                newCalendarEventDraft = EventEditDraft(from: event)
                showNewCalendarEvent = true
            },
            onDelete: { event in
                calendarVM.selectedEvent = nil
                Task { try? await calendarVM.deleteEvent(event) }
            },
            onRSVP: { event, status in
                Task { try? await calendarVM.respondToEvent(event, status: status) }
            },
            onEmailAttendees: { event in
                CalendarEventQuickActions.emailAttendees(event: event) { mode in
                    coordinator.startCompose(mode: mode)
                }
            },
            composeTo: { email in
                coordinator.startCompose(mode: .newTo(to: email))
            },
            searchSender: { email in
                Task { await coordinator.mailboxViewModel.search(query: "from:\(email)") }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
