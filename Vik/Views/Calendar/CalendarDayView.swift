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
    }

    // MARK: - All-day header

    private var allDayHeader: some View {
        let allDayEvents = viewModel.eventsForDay(viewModel.selectedDate).filter(\.isAllDay)
        return HStack(alignment: .top, spacing: 0) {
            // time-column spacer
            Text("all-day")
                .font(Typography.captionSmallRegular)
                .foregroundStyle(.secondary)
                .frame(width: CalendarLayout.timeColumnWidth, alignment: .trailing)
                .padding(.trailing, Spacing.sm)
                .padding(.vertical, Spacing.xs)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    if allDayEvents.isEmpty {
                        Color.clear.frame(height: CalendarLayout.allDayEventHeight)
                    } else {
                        ForEach(allDayEvents) { event in
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
                .background(event.resolvedColor, in: RoundedRectangle(cornerRadius: CornerRadius.xs))
        }
        .buttonStyle(.plain)
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
                        let timeEvents = viewModel.eventsForDay(viewModel.selectedDate).filter { !$0.isAllDay }
                        ForEach(timeEvents) { event in
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
                }
                .contentShape(Rectangle())
                .onHover { inside in
                    hoveredHour = inside ? hour : nil
                }
                .onTapGesture {
                    onCreateEvent(viewModel.selectedDate, hour)
                }
        }
        .id("hour-\(hour)")
    }

    // MARK: - Day event card

    private func dayEventCard(event: CalendarEvent, totalWidth: CGFloat) -> some View {
        let columnWidth = totalWidth - CalendarLayout.timeColumnWidth
        let yOffset = yPosition(for: event.startTime)
        let height = max(CalendarLayout.eventCardMinHeight, eventHeight(for: event))

        return DayEventCardView(event: event, onSelect: onSelectEvent)
            .frame(width: columnWidth - Spacing.sm * 2)
            .frame(height: height)
            .offset(x: CalendarLayout.timeColumnWidth + Spacing.sm, y: yOffset)
    }

    // MARK: - Current time indicator

    private var currentTimeIndicator: some View {
        let now = Date.now
        let yPos = yPosition(for: now)
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

    private func yPosition(for date: Date) -> CGFloat {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let totalMinutes = CGFloat((components.hour ?? 0) * 60 + (components.minute ?? 0))
        return totalMinutes / 60.0 * CalendarLayout.hourRowHeight
    }

    private func eventHeight(for event: CalendarEvent) -> CGFloat {
        let duration = event.endTime.timeIntervalSince(event.startTime)
        return CGFloat(duration / 3600.0) * CalendarLayout.hourRowHeight
    }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter
    }()

    private func hourLabel(_ hour: Int) -> String {
        guard hour != 0 else { return "" }
        let components = DateComponents(hour: hour)
        guard let date = calendar.date(from: components) else { return "" }
        return Self.hourFormatter.string(from: date)
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

    var body: some View {
        Button {
            onSelect(event)
        } label: {
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
            .scaleEffect(isHovered ? ScaleToken.hover : 1.0)
            .animation(VikAnimation.springSnappy, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    private static let timeAmPmFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private var timeRangeString: String {
        if event.isAllDay {
            return "All day"
        }
        return "\(Self.timeFormatter.string(from: event.startTime)) – \(Self.timeAmPmFormatter.string(from: event.endTime))"
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
