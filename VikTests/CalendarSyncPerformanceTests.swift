import Foundation
import Testing
import GRDB
@testable import Vik

@Suite struct CalendarSyncPerformanceTests {
    @Test func upsertEventsReplacesAttendeesAcrossAllAffectedEvents() async throws {
        let (db, tempDir) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let syncer = CalendarBackgroundSyncer(db: db)
        let seededEvents = [
            makeEventRecord(eventId: "event-1", updatedAt: 1),
            makeEventRecord(eventId: "event-2", updatedAt: 1),
        ]
        let originalAttendees = [
            makeAttendeeRecord(eventId: "event-1", email: "old-1@example.com"),
            makeAttendeeRecord(eventId: "event-2", email: "old-2@example.com"),
        ]

        try await syncer.upsertEvents(seededEvents, attendees: originalAttendees)

        let replacementAttendees = [
            makeAttendeeRecord(eventId: "event-1", email: "new-1@example.com"),
            makeAttendeeRecord(eventId: "event-2", email: "new-2@example.com"),
            makeAttendeeRecord(eventId: "event-2", email: "new-3@example.com"),
        ]

        try await syncer.upsertEvents(seededEvents, attendees: replacementAttendees)

        let persistedEmails = try await db.dbPool.read { db in
            try CalendarAttendeeRecord
                .order(Column("email"))
                .fetchAll(db)
                .map(\.email)
        }

        #expect(persistedEmails == [
            "new-1@example.com",
            "new-2@example.com",
            "new-3@example.com",
        ])
    }

    @Test func incrementalPageAppliesDeletesAndUpsertsWithoutWaitingForLaterPages() async throws {
        let (db, tempDir) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let syncer = CalendarBackgroundSyncer(db: db)
        try await syncer.upsertEvents(
            [makeEventRecord(eventId: "stale-event", updatedAt: 1)],
            attendees: [makeAttendeeRecord(eventId: "stale-event", email: "stale@example.com")]
        )

        let page = [
            CalendarAPIEvent(
                id: "stale-event",
                status: "cancelled",
                htmlLink: nil,
                created: nil,
                updated: nil,
                summary: nil,
                description: nil,
                location: nil,
                colorId: nil,
                creator: nil,
                organizer: nil,
                start: nil,
                end: nil,
                recurrence: nil,
                recurringEventId: nil,
                originalStartTime: nil,
                transparency: nil,
                visibility: nil,
                iCalUID: nil,
                sequence: nil,
                attendees: nil,
                attendeesOmitted: nil,
                conferenceData: nil,
                reminders: nil,
                attachments: nil,
                eventType: nil,
                etag: nil,
                hangoutLink: nil,
                guestsCanModify: nil,
                guestsCanInviteOthers: nil,
                guestsCanSeeOtherGuests: nil,
                extendedProperties: nil,
                isSelf: nil
            ),
            CalendarAPIEvent(
                id: "fresh-event",
                status: "confirmed",
                htmlLink: "https://example.com/events/fresh",
                created: nil,
                updated: "2026-04-09T10:00:00Z",
                summary: "Planning",
                description: "Discuss launch",
                location: "Room 1",
                colorId: "4",
                creator: nil,
                organizer: CalendarAPIPerson(email: "owner@example.com", displayName: "Owner", isSelf: true),
                start: CalendarAPIDateTime(date: nil, dateTime: "2026-04-09T10:00:00Z", timeZone: "UTC"),
                end: CalendarAPIDateTime(date: nil, dateTime: "2026-04-09T11:00:00Z", timeZone: "UTC"),
                recurrence: nil,
                recurringEventId: nil,
                originalStartTime: nil,
                transparency: nil,
                visibility: nil,
                iCalUID: "fresh-ical",
                sequence: 1,
                attendees: [
                    CalendarAPIAttendee(
                        email: "guest@example.com",
                        displayName: "Guest",
                        responseStatus: "accepted",
                        organizer: false,
                        resource: false,
                        optional: false,
                        comment: nil,
                        additionalGuests: nil,
                        isSelf: false
                    )
                ],
                attendeesOmitted: nil,
                conferenceData: nil,
                reminders: nil,
                attachments: nil,
                eventType: "default",
                etag: "\"etag-1\"",
                hangoutLink: nil,
                guestsCanModify: nil,
                guestsCanInviteOthers: nil,
                guestsCanSeeOtherGuests: nil,
                extendedProperties: nil,
                isSelf: nil
            ),
        ]

        try await CalendarSyncEngine.applyIncrementalPage(
            page,
            calendarId: "primary",
            accountId: "account",
            calendarTimeZone: "UTC",
            syncer: syncer
        )

        let staleExists = try await db.dbPool.read { db in
            try CalendarEventRecord
                .filter(Column("event_id") == "stale-event")
                .fetchCount(db) > 0
        }
        let freshEvent = try await db.dbPool.read { db in
            try CalendarEventRecord
                .filter(Column("event_id") == "fresh-event")
                .fetchOne(db)
        }
        let freshAttendees = try await db.dbPool.read { db in
            try CalendarAttendeeRecord
                .filter(Column("event_id") == "fresh-event")
                .fetchAll(db)
        }

        #expect(staleExists == false)
        #expect(freshEvent?.summary == "Planning")
        #expect(freshAttendees.map(\.email) == ["guest@example.com"])
    }

    private func makeTestDatabase() throws -> (db: MailDatabase, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let db = try MailDatabase(accountID: "account", baseDirectory: tempDir)
        try db.dbPool.write { db in
            try CalendarRecord(
                calendarId: "primary",
                accountId: "account",
                summary: "Primary",
                description: nil,
                timeZone: "UTC",
                backgroundColor: "#3A6FF0",
                foregroundColor: "#FFFFFF",
                isPrimary: true,
                accessRole: "owner",
                isVisible: true,
                summaryOverride: nil,
                syncToken: nil,
                lastSyncedAt: nil
            ).insert(db)
        }
        return (db, tempDir)
    }

    private func makeEventRecord(eventId: String, updatedAt: Double) -> CalendarEventRecord {
        CalendarEventRecord(
            eventId: eventId,
            calendarId: "primary",
            accountId: "account",
            summary: "Event \(eventId)",
            description: nil,
            location: nil,
            startTime: 1_700_000_000,
            endTime: 1_700_003_600,
            isAllDay: false,
            timeZone: "UTC",
            status: "confirmed",
            organizerEmail: "owner@example.com",
            organizerName: "Owner",
            organizerIsSelf: true,
            creatorEmail: "owner@example.com",
            selfResponseStatus: "accepted",
            colorId: nil,
            isRecurring: false,
            recurringEventId: nil,
            conferenceLink: nil,
            conferenceName: nil,
            eventType: "default",
            etag: "\"etag-\(eventId)\"",
            htmlLink: nil,
            canEdit: true,
            iCalUid: "ical-\(eventId)",
            sequence: 1,
            remindersJson: nil,
            attachmentsJson: nil,
            extendedPropertiesJson: nil,
            updatedAt: updatedAt
        )
    }

    private func makeAttendeeRecord(eventId: String, email: String) -> CalendarAttendeeRecord {
        CalendarAttendeeRecord(
            eventId: eventId,
            calendarId: "primary",
            accountId: "account",
            email: email,
            displayName: nil,
            responseStatus: "needsAction",
            isOrganizer: false,
            isResource: false,
            isOptional: false
        )
    }
}
