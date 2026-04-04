import SwiftUI

/// Shared all-day event chip used in both day and week calendar views.
/// When `width` is provided (week view), the chip is fixed-width with `Spacing.xs` padding;
/// when `nil` (day view), it uses `Spacing.sm` padding and sizes to fit.
struct CalendarAllDayChip: View {
    let event: CalendarEvent
    let actions: CalendarEventActions
    var width: CGFloat? = nil
    var dayDate: Date? = nil

    var body: some View {
        let dayLabel = dayDate.map { ", \($0.formattedWeekdayFull)" } ?? ""
        let isWeekStyle = width != nil

        Button {
            actions.onSelectEvent(event)
        } label: {
            chipLabel(isWeekStyle: isWeekStyle)
        }
        .buttonStyle(.plain)
        .contextMenu {
            CalendarEventContextMenu(
                event: event,
                onEdit: actions.onEdit,
                onDelete: actions.onDelete,
                onRSVP: actions.onRSVP,
                onEmailAttendees: actions.onEmailAttendees
            )
        }
        .accessibilityLabel("\(event.summary), all day\(dayLabel)")
        .help(event.summary)
    }

    @ViewBuilder
    private func chipLabel(isWeekStyle: Bool) -> some View {
        let label = Text(event.summary)
            .font(isWeekStyle ? Typography.calendarWeekAllDayEvent : Typography.captionSemibold)
            .foregroundStyle(CalendarColor.contrastingForeground(forId: Int(event.colorId ?? "")))
            .lineLimit(1)
            .padding(.horizontal, isWeekStyle ? Spacing.xs : Spacing.sm)
            .frame(height: CalendarLayout.allDayEventHeight)

        if let width {
            label
                .frame(width: width - 2, alignment: .leading)
                .background(event.resolvedColor.opacity(0.8), in: .rect(cornerRadius: CornerRadius.xs))
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: CornerRadius.xs))
        } else {
            label
                .background(event.resolvedColor.opacity(0.8), in: .rect(cornerRadius: CornerRadius.xs))
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: CornerRadius.xs))
        }
    }
}
