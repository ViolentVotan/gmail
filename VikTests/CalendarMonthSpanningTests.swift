import Testing
import Foundation
import SwiftUI
@testable import Vik

@Suite("Month View Spanning Algorithm")
struct CalendarMonthSpanningTests {

    /// Helper to create a CalendarEvent with all required fields filled in.
    private func makeEvent(
        id: String,
        summary: String,
        startTime: Date,
        endTime: Date,
        isAllDay: Bool = true,
        color: Color = .blue
    ) -> CalendarEvent {
        CalendarEvent(
            googleEventId: id,
            calendarId: "c",
            accountID: "a",
            summary: summary,
            description: nil,
            location: nil,
            startTime: startTime,
            endTime: endTime,
            isAllDay: isAllDay,
            timeZone: nil,
            status: .confirmed,
            organizer: nil,
            creator: nil,
            attendees: [],
            selfResponseStatus: .accepted,
            conferenceLink: nil,
            conferenceName: nil,
            colorId: nil,
            resolvedColor: color,
            isRecurring: false,
            recurringEventId: nil,
            reminders: [],
            eventType: .default,
            etag: "",
            htmlLink: nil,
            canEdit: true,
            attachments: []
        )
    }

    @Test("Single spanning event gets row 0")
    func singleSpanningEvent() {
        let cal = Calendar.current
        let monday = cal.date(from: DateComponents(year: 2026, month: 3, day: 16))!
        let weekDays = (0..<7).map { cal.date(byAdding: .day, value: $0, to: monday)! }

        // All-day event Tue–Thu (exclusive end = Fri start-of-day → weekDays[4])
        // Algorithm treats the end date inclusively in the column range.
        let event = makeEvent(
            id: "1", summary: "Trip",
            startTime: weekDays[1], endTime: weekDays[4]
        )

        let layout = MonthSpanningLayout.compute(events: [event], weekDays: weekDays)
        #expect(layout.rows.count == 1)
        #expect(layout.rows[0].startColumn == 1)
        #expect(layout.rows[0].endColumn == 4)
    }

    @Test("Two non-overlapping events share row 0")
    func nonOverlappingShareRow() {
        let cal = Calendar.current
        let monday = cal.date(from: DateComponents(year: 2026, month: 3, day: 16))!
        let weekDays = (0..<7).map { cal.date(byAdding: .day, value: $0, to: monday)! }

        let e1 = makeEvent(
            id: "1", summary: "A",
            startTime: weekDays[0], endTime: weekDays[1]
        )
        let e2 = makeEvent(
            id: "2", summary: "B",
            startTime: weekDays[3], endTime: weekDays[5],
            color: .red
        )

        let layout = MonthSpanningLayout.compute(events: [e1, e2], weekDays: weekDays)
        #expect(layout.rows.count == 2)
        #expect(layout.rows[0].rowIndex == 0)
        #expect(layout.rows[1].rowIndex == 0)
    }

    @Test("Overlapping events get different rows")
    func overlappingDifferentRows() {
        let cal = Calendar.current
        let monday = cal.date(from: DateComponents(year: 2026, month: 3, day: 16))!
        let weekDays = (0..<7).map { cal.date(byAdding: .day, value: $0, to: monday)! }

        let e1 = makeEvent(
            id: "1", summary: "Long",
            startTime: weekDays[0], endTime: weekDays[6]
        )
        let e2 = makeEvent(
            id: "2", summary: "Short",
            startTime: weekDays[2], endTime: weekDays[4],
            color: .red
        )

        let layout = MonthSpanningLayout.compute(events: [e1, e2], weekDays: weekDays)
        let rows = Set(layout.rows.map(\.rowIndex))
        #expect(rows.count == 2)
    }

    @Test("Excess events beyond max rows counted as overflow")
    func overflowCounting() {
        let cal = Calendar.current
        let monday = cal.date(from: DateComponents(year: 2026, month: 3, day: 16))!
        let weekDays = (0..<7).map { cal.date(byAdding: .day, value: $0, to: monday)! }

        let events = (0..<4).map { i in
            makeEvent(
                id: "\(i)", summary: "E\(i)",
                startTime: weekDays[0], endTime: weekDays[6]
            )
        }

        let layout = MonthSpanningLayout.compute(events: events, weekDays: weekDays)
        #expect(layout.overflowPerDay[0] >= 1)
    }
}
