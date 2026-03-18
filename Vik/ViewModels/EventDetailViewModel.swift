import SwiftUI
import Foundation
private import os

@Observable
@MainActor
final class EventDetailViewModel {

    // MARK: - State

    var event: CalendarEvent
    var isEditing = false
    var editDraft: EventEditDraft?
    var relatedEmails: [Email] = []
    var isSaving = false

    /// Conflict resolution state for optimistic concurrency (etag mismatch).
    var conflictState: ConflictState?

    enum ConflictState {
        case detected(local: CalendarEvent, remote: CalendarEvent)
        case resolved
    }

    // MARK: - Dependencies

    private let eventService = CalendarEventService.shared
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "EventDetailViewModel")

    // MARK: - Init

    init(event: CalendarEvent) {
        self.event = event
    }

    // MARK: - Editing

    func startEditing() {
        editDraft = EventEditDraft(from: event)
        isEditing = true
    }

    func cancelEditing() {
        isEditing = false
        editDraft = nil
    }

    func saveChanges() async throws {
        guard let draft = editDraft else { return }
        isSaving = true
        defer { isSaving = false }

        let input = CalendarAPIEventInput(
            summary: draft.summary,
            description: draft.description,
            location: draft.location,
            start: CalendarAPIDateTime(
                date: draft.isAllDay ? iso8601DateString(draft.startTime) : nil,
                dateTime: draft.isAllDay ? nil : iso8601String(draft.startTime),
                timeZone: event.timeZone
            ),
            end: CalendarAPIDateTime(
                date: draft.isAllDay ? iso8601DateString(draft.endTime) : nil,
                dateTime: draft.isAllDay ? nil : iso8601String(draft.endTime),
                timeZone: event.timeZone
            )
        )

        do {
            _ = try await eventService.updateEvent(
                calendarId: event.calendarId,
                eventId: event.googleEventId,
                event: input,
                accountID: event.accountID,
                etag: event.etag
            )
            isEditing = false
            editDraft = nil
        } catch {
            if case .conflict = error {
                // Fetch the remote version for conflict resolution.
                do {
                    let remoteEvent = try await eventService.getEvent(
                        calendarId: event.calendarId,
                        eventId: event.googleEventId,
                        accountID: event.accountID
                    )
                    // Build a minimal CalendarEvent from the remote API response for display.
                    conflictState = .detected(local: event, remote: makeCalendarEvent(from: remoteEvent))
                } catch {
                    Self.logger.error("Failed to fetch remote event for conflict resolution: \(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    // MARK: - Conflict Resolution

    func resolveConflict(keepLocal: Bool) async throws {
        guard case .detected(_, let remote) = conflictState else { return }
        isSaving = true
        defer { isSaving = false }

        if keepLocal {
            // Re-attempt update with the remote's etag.
            guard let draft = editDraft else { return }
            let input = CalendarAPIEventInput(
                summary: draft.summary,
                description: draft.description,
                location: draft.location,
                start: CalendarAPIDateTime(
                    date: draft.isAllDay ? iso8601DateString(draft.startTime) : nil,
                    dateTime: draft.isAllDay ? nil : iso8601String(draft.startTime),
                    timeZone: event.timeZone
                ),
                end: CalendarAPIDateTime(
                    date: draft.isAllDay ? iso8601DateString(draft.endTime) : nil,
                    dateTime: draft.isAllDay ? nil : iso8601String(draft.endTime),
                    timeZone: event.timeZone
                )
            )
            _ = try await eventService.updateEvent(
                calendarId: event.calendarId,
                eventId: event.googleEventId,
                event: input,
                accountID: event.accountID,
                etag: remote.etag
            )
        } else {
            // Accept the remote version -- update local state.
            event = remote
        }

        conflictState = .resolved
        isEditing = false
        editDraft = nil
    }

    // MARK: - Actions

    func joinConference() {
        guard let url = event.conferenceLink else { return }
        NSWorkspace.shared.open(url)
    }

    /// Searches for emails from event attendees. Populated by Task 13 (Email-Calendar integration).
    func findRelatedEmails(in db: MailDatabase) async {
        // TODO: Task 13 — Wire up MailDatabaseQueries.messagesFromSenders + GmailDataTransformer
        // let attendeeEmails = event.attendees.map(\.email)
        // guard !attendeeEmails.isEmpty else { return }
        relatedEmails = []
    }

    // MARK: - Private Helpers

    private func iso8601String(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func iso8601DateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    /// Creates a `CalendarEvent` from a `CalendarAPIEvent` response (for conflict display).
    private func makeCalendarEvent(from apiEvent: CalendarAPIEvent) -> CalendarEvent {
        let attendees = (apiEvent.attendees ?? []).map { att in
            EventAttendee(
                email: att.email ?? "",
                displayName: att.displayName,
                responseStatus: CalendarRSVPStatus(rawValue: att.responseStatus ?? "needsAction") ?? .needsAction,
                isOrganizer: att.organizer ?? false,
                isResource: att.resource ?? false,
                isOptional: att.optional ?? false
            )
        }

        let selfStatus = (apiEvent.attendees ?? [])
            .first { $0.isSelf == true }
            .flatMap { CalendarRSVPStatus(rawValue: $0.responseStatus ?? "needsAction") }
            ?? .needsAction

        let startDate = parseAPIDateTime(apiEvent.start) ?? event.startTime
        let endDate = parseAPIDateTime(apiEvent.end) ?? event.endTime
        let isAllDay = apiEvent.start?.date != nil

        return CalendarEvent(
            googleEventId: apiEvent.id ?? event.googleEventId,
            calendarId: event.calendarId,
            accountID: event.accountID,
            summary: apiEvent.summary ?? "",
            description: apiEvent.description,
            location: apiEvent.location,
            startTime: startDate,
            endTime: endDate,
            isAllDay: isAllDay,
            timeZone: apiEvent.start?.timeZone,
            status: CalendarEvent.EventStatus(rawValue: apiEvent.status ?? "confirmed") ?? .confirmed,
            organizer: apiEvent.organizer.map {
                EventPerson(email: $0.email ?? "", displayName: $0.displayName, isSelf: $0.isSelf ?? false)
            },
            creator: apiEvent.creator.map {
                EventPerson(email: $0.email ?? "", displayName: $0.displayName, isSelf: $0.isSelf ?? false)
            },
            attendees: attendees,
            selfResponseStatus: selfStatus,
            conferenceLink: findConferenceLink(apiEvent),
            conferenceName: apiEvent.conferenceData?.conferenceSolution?.name,
            colorId: apiEvent.colorId,
            resolvedColor: apiEvent.colorId.flatMap { CalendarColor.color(forId: Int($0)) } ?? event.resolvedColor,
            isRecurring: apiEvent.recurringEventId != nil,
            recurringEventId: apiEvent.recurringEventId,
            reminders: (apiEvent.reminders?.overrides ?? []).map {
                EventReminder(
                    method: EventReminder.ReminderMethod(rawValue: $0.method ?? "popup") ?? .popup,
                    minutes: $0.minutes ?? 10
                )
            },
            eventType: CalendarEvent.EventType(rawValue: apiEvent.eventType ?? "default") ?? .default,
            etag: apiEvent.etag ?? "",
            htmlLink: apiEvent.htmlLink.flatMap { URL(string: $0) },
            canEdit: apiEvent.guestsCanModify ?? false,
            attachments: (apiEvent.attachments ?? []).map {
                EventAttachment(
                    title: $0.title ?? "",
                    fileURL: $0.fileUrl.flatMap { URL(string: $0) },
                    mimeType: $0.mimeType,
                    iconURL: $0.iconLink.flatMap { URL(string: $0) }
                )
            }
        )
    }

    private func parseAPIDateTime(_ dt: CalendarAPIDateTime?) -> Date? {
        guard let dt else { return nil }
        if let dateTime = dt.dateTime {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: dateTime) ?? ISO8601DateFormatter().date(from: dateTime)
        }
        if let dateStr = dt.date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: dt.timeZone ?? "UTC") ?? .gmt
            return f.date(from: dateStr)
        }
        return nil
    }

    private func findConferenceLink(_ event: CalendarAPIEvent) -> URL? {
        if let entryPoints = event.conferenceData?.entryPoints {
            for ep in entryPoints where ep.entryPointType == "video" {
                if let uri = ep.uri { return URL(string: uri) }
            }
        }
        if let hangout = event.hangoutLink { return URL(string: hangout) }
        return nil
    }
}

// MARK: - Event Edit Draft

struct EventEditDraft: Equatable {
    var summary: String
    var description: String?
    var location: String?
    var startTime: Date
    var endTime: Date
    var isAllDay: Bool
    var attendeeEmails: [String]
    var colorId: String?

    init(from event: CalendarEvent) {
        summary = event.summary
        description = event.description
        location = event.location
        startTime = event.startTime
        endTime = event.endTime
        isAllDay = event.isAllDay
        attendeeEmails = event.attendees.map(\.email)
        colorId = event.colorId
    }
}
