import SwiftUI

// MARK: - CalendarDayView

/// Single-day time grid: time column on left, one wide event column, current-time indicator,
/// all-day section at top, click-to-create on empty slots.
struct CalendarDayView: View {

    @Bindable var viewModel: CalendarViewModel
    let onSelectEvent: (CalendarEvent) -> Void
    let onCreateEvent: (Date, Int) -> Void
    var onEdit: (CalendarEvent) -> Void = { _ in }
    var onDelete: (CalendarEvent) -> Void = { _ in }
    var onRSVP: (CalendarEvent, CalendarRSVPStatus) -> Void = { _, _ in }
    var onEmailAttendees: (CalendarEvent) -> Void = { _ in }

    // MARK: - Private state

    @State private var currentTime: Date = .now
    @State private var gridWidth: CGFloat = 300
    @State private var cachedAllDayEvents: [CalendarEvent] = []
    @State private var cachedTimedEvents: [CalendarEvent] = []
    @State private var cachedOverlapGroups: [[CalendarEvent]] = []

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
        Button {
            onSelectEvent(event)
        } label: {
            Text(event.summary)
                .font(Typography.captionSemibold)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, Spacing.sm)
                .frame(height: CalendarLayout.allDayEventHeight)
                .background(event.resolvedColor.opacity(0.8), in: RoundedRectangle(cornerRadius: CornerRadius.xs))
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: CornerRadius.xs))
        }
        .buttonStyle(.plain)
        .contextMenu {
            CalendarEventContextMenu(
                event: event,
                onEdit: onEdit,
                onDelete: onDelete,
                onRSVP: onRSVP,
                onEmailAttendees: onEmailAttendees
            )
        }
        .accessibilityLabel(event.summary)
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
                    ForEach(Array(cachedOverlapGroups.enumerated()), id: \.element.first?.id) { groupIndex, group in
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
            label: hourLabel(hour),
            selectedDate: viewModel.selectedDate,
            onCreateEvent: onCreateEvent
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

        return DayEventCardView(event: event, onSelect: onSelectEvent)
            .contextMenu {
                CalendarEventContextMenu(
                    event: event,
                    onEdit: onEdit,
                    onDelete: onDelete,
                    onRSVP: onRSVP,
                    onEmailAttendees: onEmailAttendees
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
        .animation(VikAnimation.springGentle, value: currentTime)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Helpers

    private func hourLabel(_ hour: Int) -> String {
        CalendarLayout.hourLabels[hour]
    }

    private func scrollToCurrentTime(proxy: ScrollViewProxy) {
        guard calendar.isDateInToday(viewModel.selectedDate) else { return }
        let hour = calendar.component(.hour, from: .now)
        let scrollHour = max(0, hour - 1)
        withAnimation(VikAnimation.springGentle) {
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
                    ? Color.primary.opacity(0.04)
                    : Color.clear)
                .frame(maxWidth: .infinity)
                .frame(height: CalendarLayout.hourRowHeight)
                .overlay(alignment: .top) {
                    Divider()
                        .opacity(0.04)
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

// MARK: - DayEventCardView

/// Rich event card for the day view — shows title, time range, description preview, attendee count.
private struct DayEventCardView: View {
    let event: CalendarEvent
    let onSelect: (CalendarEvent) -> Void

    @State private var isHovered = false
    @GestureState private var isPressed = false

    var body: some View {
        HStack(spacing: 0) {
            // Left color bar
            RoundedRectangle(cornerRadius: CalendarLayout.eventCardBorderWidth / 2)
                .fill(event.resolvedColor)
                .frame(width: CalendarLayout.eventCardBorderWidth)

            VStack(alignment: .leading, spacing: 2) {
                // Title
                Text(event.summary)
                    .font(Typography.calendarEventTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                // Time range
                Text(event.formattedTimeRangeCompact)
                    .font(Typography.calendarEventTime)
                    .foregroundStyle(.secondary)

                // Description preview
                if let description = event.description, !description.isEmpty {
                    Text(description)
                        .font(Typography.calendarEventTime)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // Badges row
                if event.attendees.count > 0 || event.conferenceLink != nil {
                    HStack(spacing: Spacing.sm) {
                        if event.attendees.count > 0 {
                            Label("\(event.attendees.count)", systemImage: "person.2")
                                .font(Typography.calendarEventTime)
                                .foregroundStyle(.secondary)
                        }
                        if event.conferenceLink != nil {
                            Image(systemName: "video")
                                .font(Typography.calendarEventTime)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xs)

            Spacer(minLength: 0)
        }
        .background(
            event.resolvedColor.opacity(CalendarSemanticColor.eventCardBackgroundOpacity),
            in: RoundedRectangle(cornerRadius: CornerRadius.xs)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.xs)
                .strokeBorder(
                    event.resolvedColor.opacity(isHovered ? 0.4 : 0.2),
                    lineWidth: 0.5
                )
        )
        .glassEffect(
            isHovered ? .regular.interactive() : .identity,
            in: .rect(cornerRadius: CornerRadius.xs)
        )
        .shadow(
            color: isHovered ? event.resolvedColor.opacity(0.2) : .clear,
            radius: isHovered ? 4 : 0,
            y: isHovered ? 2 : 0
        )
        .scaleEffect(isPressed ? ScaleToken.press : (isHovered ? ScaleToken.hover : 1.0))
        .animation(VikAnimation.springSnappy, value: isPressed)
        .animation(VikAnimation.springSnappy, value: isHovered)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
                .onEnded { _ in onSelect(event) }
        )
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(event.summary), \(event.formattedTimeRangeCompact)")
        .accessibilityAddTraits(.isButton)
    }

}

// MARK: - Preview

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarDayView(
        viewModel: vm,
        onSelectEvent: { _ in },
        onCreateEvent: { _, _ in }
    )
    .frame(width: 600, height: 700)
}
