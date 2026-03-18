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

    @State private var previousViewMode: CalendarViewMode = .week

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
                    .transition(directionalTransition(for: .week))

                case .day:
                    CalendarDayView(
                        viewModel: viewModel,
                        onSelectEvent: onSelectEvent,
                        onCreateEvent: onCreateEvent
                    )
                    .transition(directionalTransition(for: .day))

                case .agenda:
                    CalendarAgendaView(
                        viewModel: viewModel,
                        onSelectEvent: onSelectEvent
                    )
                    .transition(directionalTransition(for: .agenda))
                }
            }
            .animation(VikAnimation.contentSwitch, value: viewModel.viewMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onChange(of: viewModel.viewMode) { old, _ in
                previousViewMode = old
            }
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

    // MARK: - Private

    /// Maps each view mode to a positional index for directional comparison.
    private func modeIndex(_ mode: CalendarViewMode) -> Int {
        switch mode {
        case .week:   0
        case .day:    1
        case .agenda: 2
        }
    }

    /// Returns an asymmetric slide+fade transition based on the navigation direction.
    /// Moving forward (week→day, day→agenda) slides left; backward slides right.
    private func directionalTransition(for mode: CalendarViewMode) -> AnyTransition {
        let isForward = modeIndex(mode) > modeIndex(previousViewMode)
        let insertOffset: CGFloat = isForward ? OffsetToken.small : -OffsetToken.small
        let removeOffset: CGFloat = isForward ? -OffsetToken.small : OffsetToken.small
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: insertOffset)),
            removal:   .opacity.combined(with: .offset(x: removeOffset))
        )
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarContainerView(viewModel: vm)
        .frame(width: 1000, height: 700)
}
