import SwiftUI

// MARK: - CalendarContainerView

struct CalendarContainerView: View {
    @Bindable var viewModel: CalendarViewModel
    var onNewEvent: () -> Void = {}
    var onSelectEvent: (CalendarEvent) -> Void = { _ in }
    var onCreateEvent: (Date, Int) -> Void = { _, _ in }

    var onEdit: (CalendarEvent) -> Void = { _ in }
    var onDelete: (CalendarEvent) -> Void = { _ in }
    var onRSVP: (CalendarEvent, CalendarRSVPStatus) -> Void = { _, _ in }
    var onEmailAttendees: (CalendarEvent) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            CalendarHeaderView(viewModel: viewModel, onNewEvent: onNewEvent)
            Divider()

            ZStack {
                switch viewModel.viewMode {
                case .week:
                    CalendarWeekView(
                        viewModel: viewModel,
                        onSelectEvent: onSelectEvent,
                        onCreateEvent: onCreateEvent
                    )
                    .transition(.opacity)

                case .day:
                    CalendarDayView(
                        viewModel: viewModel,
                        onSelectEvent: onSelectEvent,
                        onCreateEvent: onCreateEvent
                    )
                    .transition(.opacity)

                case .agenda:
                    CalendarAgendaView(
                        viewModel: viewModel,
                        onSelectEvent: onSelectEvent
                    )
                    .transition(.opacity)
                }
            }
            .animation(VikAnimation.contentSwitch, value: viewModel.viewMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .task {
            viewModel.startObserving()
        }
        .sheet(item: $viewModel.selectedEvent) { event in
            CalendarEventDetailView(
                event: event,
                onEdit: { onEdit(event) },
                onDelete: { onDelete(event) },
                onRSVP: { status in onRSVP(event, status) },
                onEmailAttendees: { onEmailAttendees(event) },
                onDismiss: { viewModel.selectedEvent = nil }
            )
            .frame(minWidth: 420, maxWidth: 420, minHeight: 300, maxHeight: 600)
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarContainerView(viewModel: vm)
        .frame(width: 1000, height: 700)
}
