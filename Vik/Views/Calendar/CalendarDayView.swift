import SwiftUI

// MARK: - CalendarDayView

/// Single-day time grid: time column on left, one wide event column, current-time indicator,
/// all-day section at top, click-to-create on empty slots.
struct CalendarDayView: View {

    @Bindable var viewModel: CalendarViewModel
    let onSelectEvent: (CalendarEvent) -> Void
    let onCreateEvent: (Date, Int) -> Void

    // MARK: - Private state

    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var hoveredHour: Int? = nil
    @State private var cachedAllDayEvents: [CalendarEvent] = []
    @State private var cachedTimedEvents: [CalendarEvent] = []

    private let hours = Array(0..<24)
    private var calendar: Calendar { .current }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            allDayHeader
            Divider()
            timeGrid
        }
        .animation(VikAnimation.contentSwitch, value: viewModel.selectedDate)
        .task(id: viewModel.selectedDate) {
            recomputeEvents()
        }
        .onChange(of: viewModel.events) {
            recomputeEvents()
        }
    }

    private func recomputeEvents() {
        let allEvents = viewModel.eventsForDay(viewModel.selectedDate)
        cachedAllDayEvents = allEvents.filter(\.isAllDay)
        cachedTimedEvents = allEvents.filter { !$0.isAllDay }
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
        .accessibilityLabel(event.summary)
    }

    // MARK: - Time grid

    private var timeGrid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    // Hour rows
                    VStack(spacing: 0) {
                        ForEach(hours, id: \.self) { hour in
                            hourRow(hour: hour)
                        }
                    }

                    // Event cards overlaid on the grid
                    GeometryReader { geo in
                        ForEach(cachedTimedEvents) { event in
                            dayEventCard(event: event, totalWidth: geo.size.width)
                        }
                    }

                    // Current time indicator
                    if calendar.isDateInToday(viewModel.selectedDate) {
                        currentTimeIndicator
                    }
                }
                .id("grid")
            }
            .onAppear {
                scrollProxy = proxy
                scrollToCurrentTime(proxy: proxy)
            }
            .onChange(of: viewModel.selectedDate) { _, _ in
                scrollToCurrentTime(proxy: proxy)
            }
        }
    }

    // MARK: - Hour row

    private func hourRow(hour: Int) -> some View {
        HStack(spacing: 0) {
            // Time label
            Text(hourLabel(hour))
                .font(Typography.captionSmallRegular)
                .foregroundStyle(.secondary)
                .frame(width: CalendarLayout.timeColumnWidth, alignment: .trailing)
                .padding(.trailing, Spacing.sm)
                .frame(height: CalendarLayout.hourRowHeight)

            // Tappable slot area
            Rectangle()
                .fill(hoveredHour == hour
                    ? Color.primary.opacity(0.04)
                    : Color.clear)
                .frame(maxWidth: .infinity)
                .frame(height: CalendarLayout.hourRowHeight)
                .overlay(alignment: .top) {
                    Divider()
                        .opacity(0.04)
                }
                .contentShape(Rectangle())
                .onHover { inside in
                    hoveredHour = inside ? hour : nil
                }
                .onTapGesture {
                    onCreateEvent(viewModel.selectedDate, hour)
                }
                .accessibilityLabel(hour == 0 ? "Create event at midnight" : "Create event at \(hourLabel(hour))")
                .accessibilityAddTraits(.isButton)
        }
        .id("hour-\(hour)")
    }

    // MARK: - Day event card

    private func dayEventCard(event: CalendarEvent, totalWidth: CGFloat) -> some View {
        let columnWidth = totalWidth - CalendarLayout.timeColumnWidth
        let yOffset = CalendarLayout.yPosition(for: event.startTime)
        let height = max(
            CalendarLayout.eventCardMinHeight,
            CalendarLayout.eventHeight(start: event.startTime, end: event.endTime)
        )

        return DayEventCardView(event: event, onSelect: onSelectEvent)
            .frame(width: columnWidth - Spacing.sm * 2)
            .frame(height: height)
            .offset(x: CalendarLayout.timeColumnWidth + Spacing.sm, y: yOffset)
    }

    // MARK: - Current time indicator

    private var currentTimeIndicator: some View {
        let now = Date.now
        let yPos = CalendarLayout.yPosition(for: now)
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
    }

    // MARK: - Helpers

    private func hourLabel(_ hour: Int) -> String {
        guard hour != 0 else { return "" }
        let components = DateComponents(hour: hour)
        guard let date = calendar.date(from: components) else { return "" }
        return date.formattedCalendarHour
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
                    .font(Typography.captionSemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                // Time range
                Text(timeRangeString)
                    .font(Typography.captionSmallRegular)
                    .foregroundStyle(.secondary)

                // Description preview
                if let description = event.description, !description.isEmpty {
                    Text(description)
                        .font(Typography.captionSmallRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // Badges row
                if event.attendees.count > 0 || event.conferenceLink != nil {
                    HStack(spacing: Spacing.sm) {
                        if event.attendees.count > 0 {
                            Label("\(event.attendees.count)", systemImage: "person.2")
                                .font(Typography.captionSmallRegular)
                                .foregroundStyle(.secondary)
                        }
                        if event.conferenceLink != nil {
                            Image(systemName: "video")
                                .font(Typography.captionSmallRegular)
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
        .accessibilityLabel("\(event.summary), \(timeRangeString)")
        .accessibilityAddTraits(.isButton)
    }

    private var timeRangeString: String {
        if event.isAllDay {
            return "All day"
        }
        return "\(event.startTime.formattedCalendarTime) – \(event.endTime.formattedCalendarTimeAmPm)"
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
