import Foundation
import Testing
@testable import Vik

@Suite struct CalendarEventServiceRequestTests {
    @Test func updateRequestsUsePatchAndInferConferenceSupport() throws {
        let event = CalendarAPIEventInput(
            summary: "Review",
            description: nil,
            location: nil,
            start: CalendarAPIDateTime(date: nil, dateTime: "2026-04-09T10:00:00Z", timeZone: "UTC"),
            end: CalendarAPIDateTime(date: nil, dateTime: "2026-04-09T11:00:00Z", timeZone: "UTC"),
            attendees: nil,
            reminders: nil,
            conferenceData: CalendarAPIConferenceData(
                createRequest: CalendarAPICreateConferenceRequest(
                    requestId: "request-1",
                    conferenceSolutionKey: CalendarAPIConferenceSolutionKey(type: "hangoutsMeet")
                ),
                entryPoints: nil,
                conferenceSolution: nil,
                conferenceId: nil,
                signature: nil,
                notes: nil
            ),
            colorId: nil,
            recurrence: nil,
            transparency: nil,
            visibility: nil,
            guestsCanModify: nil,
            guestsCanInviteOthers: nil,
            extendedProperties: nil,
            attachments: nil
        )

        let request = try CalendarEventService.prepareMutationRequest(
            event: event,
            method: "PUT",
            etag: "\"etag-1\"",
            sendUpdates: "all"
        )

        #expect(request.method == "PATCH")
        #expect(queryValue(named: "conferenceDataVersion", in: request.queryItems) == "1")
    }

    @Test func insertRequestsAdvertiseAttachmentSupportWhenNeeded() throws {
        let event = CalendarAPIEventInput(
            summary: "Spec",
            description: nil,
            location: nil,
            start: CalendarAPIDateTime(date: nil, dateTime: "2026-04-09T10:00:00Z", timeZone: "UTC"),
            end: CalendarAPIDateTime(date: nil, dateTime: "2026-04-09T11:00:00Z", timeZone: "UTC"),
            attendees: nil,
            reminders: nil,
            conferenceData: nil,
            colorId: nil,
            recurrence: nil,
            transparency: nil,
            visibility: nil,
            guestsCanModify: nil,
            guestsCanInviteOthers: nil,
            extendedProperties: nil,
            attachments: [
                CalendarAPIAttachment(
                    fileUrl: "https://drive.google.com/file/d/123/view",
                    title: "Doc",
                    mimeType: "application/pdf",
                    iconLink: nil,
                    fileId: "123"
                )
            ]
        )

        let request = try CalendarEventService.prepareMutationRequest(
            event: event,
            method: "POST",
            etag: nil,
            sendUpdates: "externalOnly"
        )

        #expect(queryValue(named: "supportsAttachments", in: request.queryItems) == "true")
        #expect(queryValue(named: "sendUpdates", in: request.queryItems) == "externalOnly")
    }

    @Test func quickAddQueryItemsIncludeSendUpdates() {
        let queryItems = CalendarEventService.quickAddQueryItems(
            text: "Lunch with Alex tomorrow at noon",
            sendUpdates: "externalOnly"
        )

        #expect(queryValue(named: "text", in: queryItems) == "Lunch with Alex tomorrow at noon")
        #expect(queryValue(named: "sendUpdates", in: queryItems) == "externalOnly")
    }

    private func queryValue(named name: String, in items: [URLQueryItem]) -> String? {
        items.first(where: { $0.name == name })?.value
    }
}
