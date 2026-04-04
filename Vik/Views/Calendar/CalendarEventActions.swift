import SwiftUI

/// Bundles the 6 event-action callbacks shared by all calendar views.
/// Eliminates repetitive parameter declarations in CalendarContainerView,
/// CalendarDayView, CalendarWeekView, CalendarMonthView, and CalendarAgendaView.
struct CalendarEventActions {
    var onSelectEvent: (CalendarEvent) -> Void = { _ in }
    var onCreateEvent: (Date, Int) -> Void = { _, _ in }
    var onEdit: (CalendarEvent) -> Void = { _ in }
    var onDelete: (CalendarEvent) -> Void = { _ in }
    var onRSVP: (CalendarEvent, CalendarRSVPStatus) -> Void = { _, _ in }
    var onEmailAttendees: (CalendarEvent) -> Void = { _ in }
}
