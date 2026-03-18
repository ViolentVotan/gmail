import SwiftUI

// MARK: - CalendarContainerView

struct CalendarContainerView: View {
    @Bindable var viewModel: CalendarViewModel
    var onNewEvent: () -> Void = {}
    var onSelectEvent: (CalendarEvent) -> Void = { _ in }
    var onCreateEvent: (Date, Int) -> Void = { _, _ in }

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
        .task {
            viewModel.startObserving()
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarContainerView(viewModel: vm)
        .frame(width: 1000, height: 700)
}
