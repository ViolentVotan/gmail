import Foundation
import Testing
@testable import Vik

@MainActor
@Suite struct CalendarEventEditorViewModelTests {
    @Test func newEventWithGoogleMeetAddsConferenceCreateRequest() {
        let viewModel = CalendarEventEditorViewModel(calendars: [makeCalendarInfo()])
        viewModel.populateFromDraft(nil, defaultStartTime: Date(timeIntervalSince1970: 1_700_000_000))
        viewModel.summary = "Standup"
        viewModel.selectedCalendarID = "primary"
        viewModel.addGoogleMeet = true

        var captured: CalendarAPIEventInput?
        viewModel.commitSave(editDraft: nil, scope: nil) { input, _, _ in
            captured = input
        }

        let createRequest = captured?.conferenceData?.createRequest
        #expect(createRequest != nil)
        #expect(createRequest?.conferenceSolutionKey.type == "hangoutsMeet")
        #expect(createRequest?.requestId.isEmpty == false)
    }

    @Test func editingEventWithUnchangedRemindersOmitsReminderPatch() {
        let viewModel = CalendarEventEditorViewModel(calendars: [makeCalendarInfo()])
        let draft = makeEditDraft(
            reminders: [EventReminder(method: .popup, minutes: 30)]
        )
        viewModel.populateFromDraft(draft, defaultStartTime: nil)

        var captured: CalendarAPIEventInput?
        viewModel.commitSave(editDraft: draft, scope: nil) { input, _, _ in
            captured = input
        }

        #expect(captured?.reminders == nil)
    }

    @Test func editingEventWithClearedDescriptionSendsExplicitEmptyValue() {
        let viewModel = CalendarEventEditorViewModel(calendars: [makeCalendarInfo()])
        let draft = makeEditDraft(description: "Discuss roadmap")
        viewModel.populateFromDraft(draft, defaultStartTime: nil)
        viewModel.eventDescription = ""

        var captured: CalendarAPIEventInput?
        viewModel.commitSave(editDraft: draft, scope: nil) { input, _, _ in
            captured = input
        }

        #expect(captured?.description == "")
    }

    private func makeCalendarInfo() -> CalendarInfo {
        CalendarInfo(
            id: "test_primary",
            calendarId: "primary",
            accountID: "account",
            summary: "Primary",
            description: nil,
            timeZone: "Europe/Luxembourg",
            backgroundColor: "#0000FF",
            foregroundColor: "#FFFFFF",
            isPrimary: true,
            accessRole: .owner,
            isVisible: true,
            summaryOverride: nil
        )
    }

    private func makeEditDraft(
        description: String? = nil,
        reminders: [EventReminder] = []
    ) -> EventEditDraft {
        EventEditDraft(
            summary: "Planning",
            description: description,
            location: "Room 1",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_003_600),
            isAllDay: false,
            attendeeEmails: ["one@example.com"],
            reminders: reminders,
            hasConferenceLink: false,
            colorId: "4",
            calendarId: "primary",
            isRecurring: false,
            googleEventId: "event-1",
            accountID: "account",
            etag: "\"etag-1\""
        )
    }
}
