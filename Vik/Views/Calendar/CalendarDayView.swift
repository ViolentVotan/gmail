import SwiftUI

// MARK: - CalendarDayView

/// Single-day time grid: time column on left, one wide event column, current-time indicator,
/// all-day section at top, click-to-create on empty slots.
struct CalendarDayView: View {

    @Bindable var viewModel: CalendarViewModel
    var actions: CalendarEventActions = CalendarEventActions()

    // MARK: - Private state

    @State private var currentTime: Date = .now
    @State private var gridWidth: CGFloat = 300
    @State private var cachedAllDayEvents: [CalendarEvent] = []
    @State private var cachedTimedEvents: [CalendarEvent] = []
    @State private var cachedOverlapGroups: [[CalendarEvent]] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let hours = Array(0..<24)
    private let calendar: Calendar = .current

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            allDayHeader
            Divider()
            timeGrid
        }
        .task(id: viewModel.selectedDate) {
            recomputeEvents()
        }
        .onChange(of: viewModel.events) {
            recomputeEvents()
        }
        .task(id: calendar.isDateInToday(viewModel.selectedDate)) {
            guard calendar.isDateInToday(viewModel.selectedDate) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                currentTime = .now
            }
        }
    }

    private func recomputeEvents() {
        let allEvents = viewModel.eventsForDay(viewModel.selectedDate)
        let (allDay, timed) = allEvents.partitioned()
        cachedAllDayEvents = allDay
        cachedTimedEvents = timed
        cachedOverlapGroups = timed.overlapGroups()
    }

    // MARK: - All-day header

    private var allDayHeader: some View {
        HStack(alignment: .top, spacing: 0) {
            // time-column spacer
            Text("all-day")
                .font(Typography.captionSmallRegular)
                .foregroundStyle(.secondary)
                .frame(width: CalendarLayout.timeColumnWidth, alignment: .trailing)
                .padding(.trailing, Spacing.sm)
                .padding(.vertical, Spacing.xs)

            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer {
                    HStack(spacing: Spacing.xs) {
                        if cachedAllDayEvents.isEmpty {
                            Color.clear.frame(height: CalendarLayout.allDayEventHeight)
                        } else {
                            ForEach(cachedAllDayEvents) { event in
                                allDayChip(event)
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xs)
                }
            }
        }
        .background(.background)
    }

    private func allDayChip(_ event: CalendarEvent) -> some View {
        CalendarAllDayChip(event: event, actions: actions)
    }

    // MARK: - Time grid

    private var timeGrid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    // Hour rows
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(hours, id: \.self) { hour in
                            hourRow(hour: hour)
                        }
                    }

                    // Event cards overlaid on the grid
                    let dayStartOfDay = Calendar.current.startOfDay(for: viewModel.selectedDate)
                    ForEach(Array(cachedOverlapGroups.enumerated()), id: \.offset) { groupIndex, group in
                        ForEach(Array(group.enumerated()), id: \.element.id) { colIndex, event in
                            dayEventCard(
                                event: event,
                                colIndex: colIndex,
                                colCount: group.count,
                                totalWidth: gridWidth,
                                startOfDay: dayStartOfDay
                            )
                        }
                    }

                    // Current time indicator
                    if calendar.isDateInToday(viewModel.selectedDate) {
                        currentTimeIndicator
                    }
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    gridWidth = newWidth
                }
                .id("grid")
            }
            .task {
                scrollToCurrentTime(proxy: proxy)
            }
            .onChange(of: viewModel.selectedDate) { _, _ in
                scrollToCurrentTime(proxy: proxy)
            }
        }
    }

    // MARK: - Hour row

    private func hourRow(hour: Int) -> some View {
        CalendarDayHourRow(
            hour: hour,
            label: CalendarLayout.hourLabels[hour],
            selectedDate: viewModel.selectedDate,
            onCreateEvent: actions.onCreateEvent
        )
    }

    // MARK: - Day event card

    private func dayEventCard(
        event: CalendarEvent,
        colIndex: Int,
        colCount: Int,
        totalWidth: CGFloat,
        startOfDay: Date
    ) -> some View {
        let columnWidth = totalWidth - CalendarLayout.timeColumnWidth
        let yOffset = CalendarLayout.yPosition(for: event.startTime, startOfDay: startOfDay)
        let height = CalendarLayout.eventHeight(start: event.startTime, end: event.endTime, clampToMinHeight: true)
        let colWidth = (columnWidth - 4) / CGFloat(colCount)
        let xOffset = CalendarLayout.timeColumnWidth + CGFloat(colIndex) * colWidth + 2

        return CalendarEventCard(event: event, style: .detailed, onSelect: actions.onSelectEvent)
            .contextMenu {
                CalendarEventContextMenu(
                    event: event,
                    onEdit: actions.onEdit,
                    onDelete: actions.onDelete,
                    onRSVP: actions.onRSVP,
                    onEmailAttendees: actions.onEmailAttendees
                )
            }
            .frame(width: colWidth - 1)
            .frame(height: height)
            .offset(x: xOffset, y: yOffset)
    }

    // MARK: - Current time indicator

    private var currentTimeIndicator: some View {
        let yPos = CalendarLayout.yPosition(for: currentTime, startOfDay: Calendar.current.startOfDay(for: currentTime))
        return HStack(spacing: 0) {
            Spacer().frame(width: CalendarLayout.timeColumnWidth - CalendarLayout.currentTimeIndicatorDotSize / 2)
            Circle()
                .fill(CalendarSemanticColor.currentTimeIndicator)
                .frame(
                    width: CalendarLayout.currentTimeIndicatorDotSize,
                    height: CalendarLayout.currentTimeIndicatorDotSize
                )
            Rectangle()
                .fill(CalendarSemanticColor.currentTimeIndicator)
                .frame(height: CalendarLayout.currentTimeIndicatorHeight)
        }
        .offset(y: yPos)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Helpers



    private func scrollToCurrentTime(proxy: ScrollViewProxy) {
        guard calendar.isDateInToday(viewModel.selectedDate) else { return }
        let hour = calendar.component(.hour, from: .now)
        let scrollHour = max(0, hour - 1)
        withAnimation(reduceMotion ? nil : VikAnimation.springGentle) {
            proxy.scrollTo("hour-\(scrollHour)", anchor: .top)
        }
    }

}

// MARK: - CalendarDayHourRow

/// Single hour row in CalendarDayView. Uses local `isHovered` state so only this
/// row re-evaluates on cursor enter/exit — not all 24 rows.
private struct CalendarDayHourRow: View {
    let hour: Int
    let label: String
    let selectedDate: Date
    let onCreateEvent: (Date, Int) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Time label
            Text(label)
                .font(Typography.captionSmallRegular)
                .foregroundStyle(.secondary)
                .frame(width: CalendarLayout.timeColumnWidth, alignment: .trailing)
                .padding(.trailing, Spacing.sm)
                .frame(height: CalendarLayout.hourRowHeight)

            // Tappable slot area
            Rectangle()
                .fill(isHovered
                    ? Color.primary.opacity(OpacityToken.subtle)
                    : Color.clear)
                .frame(maxWidth: .infinity)
                .frame(height: CalendarLayout.hourRowHeight)
                .overlay(alignment: .top) {
                    Divider()
                        .opacity(OpacityToken.subtle)
                }
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .onTapGesture {
                    onCreateEvent(selectedDate, hour)
                }
                .accessibilityLabel(hour == 0 ? "Create event at midnight" : "Create event at \(label)")
                .accessibilityAddTraits(.isButton)
        }
        .id("hour-\(hour)")
    }
}



// MARK: - Preview

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarDayView(viewModel: vm)
    .frame(width: 600, height: 700)
}
