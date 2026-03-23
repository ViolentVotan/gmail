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
    var composeTo: ((String) -> Void)?
    var searchSender: ((String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousViewMode: CalendarViewMode = .month

    var body: some View {
        VStack(spacing: 0) {
            CalendarHeaderView(viewModel: viewModel, onNewEvent: onNewEvent)
            Divider()

            ZStack {
                switch viewModel.viewMode {
                case .month:
                    CalendarMonthView(
                        viewModel: viewModel,
                        onSelectEvent: onSelectEvent,
                        onCreateEvent: onCreateEvent,
                        onEdit: onEdit,
                        onDelete: onDelete,
                        onRSVP: onRSVP,
                        onEmailAttendees: onEmailAttendees
                    )
                    .transition(directionalTransition(for: .month))

                case .week:
                    CalendarWeekView(
                        viewModel: viewModel,
                        onSelectEvent: onSelectEvent,
                        onCreateEvent: onCreateEvent,
                        onEdit: onEdit,
                        onDelete: onDelete,
                        onRSVP: onRSVP,
                        onEmailAttendees: onEmailAttendees
                    )
                    .transition(directionalTransition(for: .week))

                case .day:
                    CalendarDayView(
                        viewModel: viewModel,
                        onSelectEvent: onSelectEvent,
                        onCreateEvent: onCreateEvent,
                        onEdit: onEdit,
                        onDelete: onDelete,
                        onRSVP: onRSVP,
                        onEmailAttendees: onEmailAttendees
                    )
                    .transition(directionalTransition(for: .day))

                case .agenda:
                    CalendarAgendaView(
                        viewModel: viewModel,
                        onSelectEvent: onSelectEvent,
                        onCreateEvent: onCreateEvent,
                        onEdit: onEdit,
                        onDelete: onDelete,
                        onRSVP: onRSVP,
                        onEmailAttendees: onEmailAttendees
                    )
                    .transition(directionalTransition(for: .agenda))
                }
            }
            .animation(reduceMotion ? nil : VikAnimation.contentSwitch, value: viewModel.viewMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onChange(of: viewModel.viewMode) { old, _ in
                previousViewMode = old
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(item: $viewModel.selectedEvent) { event in
            CalendarEventDetailView(
                event: event,
                onEdit: { onEdit(event) },
                onDelete: { onDelete(event) },
                onRSVP: { status in onRSVP(event, status) },
                onEmailAttendees: { onEmailAttendees(event) },
                onDismiss: { viewModel.selectedEvent = nil },
                composeTo: composeTo,
                searchSender: searchSender
            )
            .frame(minWidth: 420, idealWidth: 420, maxWidth: 560, minHeight: 300, maxHeight: 600)
        }
    }

    // MARK: - Private

    /// Maps each view mode to a positional index for directional comparison.
    private func modeIndex(_ mode: CalendarViewMode) -> Int {
        switch mode {
        case .month:  0
        case .week:   1
        case .day:    2
        case .agenda: 3
        }
    }

    /// Returns an asymmetric slide+fade transition based on the navigation direction.
    /// Moving forward (week→day, day→agenda) slides left; backward slides right.
    private func directionalTransition(for mode: CalendarViewMode) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
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
