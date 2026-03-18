import Foundation
internal import GRDB
private import os

/// Orchestrates calendar sync for a single Google account.
/// Owns the sync lifecycle: initial full fetch, incremental delta sync via syncTokens,
/// and periodic calendar list refresh. Heavy I/O is delegated to `CalendarBackgroundSyncer`.
///
/// Adaptive polling: interval adjusts based on whether the calendar view is active,
/// the app is focused, or a recent edit was made (post-edit tightening).
actor CalendarSyncEngine {

    // MARK: - State

    enum State: Sendable {
        case idle
        case initialSync
        case syncing
        case error(CalendarAPIError)
    }

    private(set) var state: State = .idle
    let accountID: String

    // MARK: - Dependencies

    private let db: MailDatabase
    private let syncer: CalendarBackgroundSyncer
    private let eventService: CalendarEventService
    private let listService: CalendarListService

    nonisolated private static let logger = Logger(category: "CalendarSyncEngine")

    // MARK: - Adaptive Polling

    private var pollingInterval: TimeInterval = 60
    static let calendarActiveInterval: TimeInterval = 30
    static let postEditInterval: TimeInterval = 15
    static let mailActiveInterval: TimeInterval = 60
    static let backgroundInterval: TimeInterval = 300

    // MARK: - Tasks

    private var syncTask: Task<Void, Never>?
    private var calendarListSyncTask: Task<Void, Never>?
    private var postEditRevertTask: Task<Void, Never>?

    /// Sync token for incremental calendar list sync via `CalendarListService.syncCalendars`.
    private var calendarListSyncToken: String?

    /// Reentrancy guard: prevents overlapping `syncIncremental()` runs.
    /// The polling loop and user-triggered `triggerSync()` can both call
    /// `syncIncremental()` — actor reentrancy allows the second call to start
    /// while the first is suspended at an `await`. This flag is set/cleared
    /// synchronously (no `await` between check and set), so it's actor-safe.
    private var isSyncingIncrementally = false

    // MARK: - Init

    @MainActor init(accountID: String, db: MailDatabase) {
        self.accountID = accountID
        self.db = db
        self.syncer = CalendarBackgroundSyncer(db: db)
        self.eventService = .shared
        self.listService = .shared
    }

    // MARK: - Lifecycle

    /// Starts the calendar sync lifecycle.
    /// Performs initial sync if no sync tokens exist, then starts incremental polling.
    func start() async {
        let hasTokens = (try? await db.dbPool.read { db in
            try CalendarRecord
                .filter(Column("account_id") == accountID)
                .filter(Column("sync_token") != nil)
                .fetchCount(db) > 0
        }) ?? false

        if !hasTokens {
            await performInitialSync()
        }

        startIncrementalLoop()
        startCalendarListSyncLoop()
    }

    /// Stops all sync tasks, awaiting in-flight work so that
    /// `CalendarBackgroundSyncer` DB writes complete before the engine is discarded.
    func stop() async {
        syncTask?.cancel()
        calendarListSyncTask?.cancel()
        postEditRevertTask?.cancel()
        // Wait for in-flight tasks to actually finish before clearing refs
        await syncTask?.value
        await calendarListSyncTask?.value
        await postEditRevertTask?.value
        syncTask = nil
        calendarListSyncTask = nil
        postEditRevertTask = nil
    }

    /// Triggers an immediate incremental sync (e.g., after an event edit).
    func triggerSync() async {
        await syncIncremental()
    }

    /// Adjusts polling interval based on app state.
    func updatePollingInterval(calendarActive: Bool, appFocused: Bool) {
        if !appFocused {
            pollingInterval = Self.backgroundInterval
        } else if calendarActive {
            pollingInterval = Self.calendarActiveInterval
        } else {
            pollingInterval = Self.mailActiveInterval
        }
    }

    /// Temporarily tightens polling after a local edit (RSVP, create, delete).
    /// Reverts to calendar-active interval after 120 seconds.
    func temporarilyTightenPolling() {
        pollingInterval = Self.postEditInterval
        postEditRevertTask?.cancel()
        postEditRevertTask = Task {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            pollingInterval = Self.calendarActiveInterval
        }
    }

    // MARK: - Initial Sync

    private func performInitialSync() async {
        state = .initialSync

        do {
            // 1. Fetch calendar list
            let (calendars, listSyncToken) = try await listService.listCalendars(accountID: accountID)
            let records = calendars.compactMap { Self.calendarRecord(from: $0, accountId: accountID) }
            try await syncer.upsertCalendars(records)
            calendarListSyncToken = listSyncToken

            // 2. For each visible calendar: fetch events (-30d to +90d)
            let now = Date()
            let timeMin = now.addingTimeInterval(-30 * 86400)
            let timeMax = now.addingTimeInterval(90 * 86400)

            for (index, calendar) in records.enumerated() where calendar.isVisible {
                // Pace API calls to avoid 429s during initial sync of many calendars
                if index > 0 {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                do {
                    try await syncFullEvents(
                        calendarId: calendar.calendarId,
                        timeMin: timeMin,
                        timeMax: timeMax,
                        calendarTimeZone: calendar.timeZone
                    )
                } catch {
                    Self.logger.warning("Initial sync failed for calendar \(calendar.calendarId): \(String(describing: error))")
                    // Continue with other calendars
                }
            }

            state = .idle
        } catch let error as CalendarAPIError {
            state = .error(error)
            Self.logger.error("Initial calendar sync failed: \(String(describing: error))")
        } catch {
            state = .error(.networkError(error))
            Self.logger.error("Initial calendar sync failed: \(String(describing: error))")
        }
    }

    /// Full event fetch for a single calendar with pagination, storing the sync token.
    private func syncFullEvents(calendarId: String, timeMin: Date, timeMax: Date, calendarTimeZone: String? = nil) async throws {
        var allEvents: [CalendarAPIEvent] = []
        var pageToken: String? = nil
        var syncToken: String? = nil

        repeat {
            let response = try await eventService.listEvents(
                calendarId: calendarId,
                accountID: accountID,
                timeMin: timeMin,
                timeMax: timeMax,
                singleEvents: true,
                maxResults: 250,
                pageToken: pageToken
            )
            allEvents.append(contentsOf: response.items ?? [])
            pageToken = response.nextPageToken
            if response.nextSyncToken != nil { syncToken = response.nextSyncToken }
            // Pace pagination requests to avoid 429s
            if pageToken != nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
        } while pageToken != nil

        let (eventRecords, attendeeRecords) = Self.convertToRecords(
            events: allEvents, calendarId: calendarId, accountId: accountID,
            calendarTimeZone: calendarTimeZone
        )
        try await syncer.upsertEvents(eventRecords, attendees: attendeeRecords)

        if let syncToken {
            try await syncer.updateSyncToken(
                calendarId: calendarId, accountId: accountID, token: syncToken
            )
        }
    }

    // MARK: - Incremental Sync

    private func syncIncremental() async {
        if case .initialSync = state { return }
        guard NetworkMonitor.isReachable else { return }
        guard !isSyncingIncrementally else { return }
        isSyncingIncrementally = true
        defer { isSyncingIncrementally = false }
        state = .syncing

        do {
            let calendars = try await db.dbPool.read { db in
                try MailDatabaseQueries.visibleCalendars(accountId: accountID, in: db)
            }

            for calendar in calendars {
                guard let syncToken = calendar.syncToken, !syncToken.isEmpty else { continue }

                do {
                    var allCancelled: [CalendarAPIEvent] = []
                    var allActive: [CalendarAPIEvent] = []
                    var pageToken: String? = nil
                    var finalSyncToken: String? = nil

                    // Note: singleEvents is intentionally not passed here. Google's sync token
                    // remembers the expansion mode from the initial listEvents(singleEvents: true).
                    // Passing it with a syncToken may cause API errors per Google's docs.
                    repeat {
                        let response = try await eventService.syncEvents(
                            calendarId: calendar.calendarId,
                            accountID: accountID,
                            syncToken: syncToken,
                            pageToken: pageToken
                        )

                        let items = response.items ?? []
                        allCancelled.append(contentsOf: items.filter { $0.status == "cancelled" })
                        allActive.append(contentsOf: items.filter { $0.status != "cancelled" })

                        pageToken = response.nextPageToken
                        if response.nextSyncToken != nil { finalSyncToken = response.nextSyncToken }
                    } while pageToken != nil

                    if !allCancelled.isEmpty {
                        let deleteIds = allCancelled.compactMap { event -> (eventId: String, calendarId: String, accountId: String)? in
                            guard let id = event.id else { return nil }
                            return (eventId: id, calendarId: calendar.calendarId, accountId: accountID)
                        }
                        try await syncer.deleteEvents(deleteIds)
                    }

                    if !allActive.isEmpty {
                        let (eventRecords, attendeeRecords) = Self.convertToRecords(
                            events: allActive, calendarId: calendar.calendarId, accountId: accountID,
                            calendarTimeZone: calendar.timeZone
                        )
                        try await syncer.upsertEvents(eventRecords, attendees: attendeeRecords)
                    }

                    if let finalSyncToken {
                        try await syncer.updateSyncToken(
                            calendarId: calendar.calendarId, accountId: accountID, token: finalSyncToken
                        )
                    }
                } catch CalendarAPIError.gone {
                    // SyncToken expired — clear stale events and trigger full resync for this calendar
                    // Per Google Calendar API 410 spec: wipe local store before full resync
                    // to remove server-side deletions that won't appear in the new full fetch.
                    Self.logger.warning("SyncToken expired for calendar \(calendar.calendarId), performing full resync")
                    try? await syncer.deleteEventsForCalendar(
                        calendarId: calendar.calendarId, accountId: accountID
                    )
                    let now = Date()
                    let timeMin = now.addingTimeInterval(-30 * 86400)
                    let timeMax = now.addingTimeInterval(90 * 86400)
                    do {
                        try await syncFullEvents(
                            calendarId: calendar.calendarId,
                            timeMin: timeMin,
                            timeMax: timeMax,
                            calendarTimeZone: calendar.timeZone
                        )
                    } catch {
                        Self.logger.error("Full resync failed for calendar \(calendar.calendarId): \(String(describing: error))")
                    }
                } catch {
                    Self.logger.error("Incremental sync failed for calendar \(calendar.calendarId): \(String(describing: error))")
                }
            }

            state = .idle
        } catch {
            state = .error(CalendarAPIError.wrap(error))
            Self.logger.error("Incremental calendar sync failed: \(String(describing: error))")
        }
    }

    private func startIncrementalLoop() {
        syncTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollingInterval))
                guard !Task.isCancelled else { break }
                await syncIncremental()
            }
        }
    }

    // MARK: - Calendar List Refresh

    private func startCalendarListSyncLoop() {
        calendarListSyncTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await syncCalendarList()
            }
        }
    }

    private func syncCalendarList() async {
        do {
            if let token = calendarListSyncToken {
                // Incremental sync — only changed calendars
                do {
                    let response = try await listService.syncCalendars(accountID: accountID, syncToken: token)
                    let items = response.items ?? []

                    // Partition: deleted entries are removed, the rest are upserted
                    let deletedIds = items
                        .filter { $0.deleted == true }
                        .compactMap { entry -> (calendarId: String, accountId: String)? in
                            guard let id = entry.id else { return nil }
                            return (calendarId: id, accountId: accountID)
                        }
                    if !deletedIds.isEmpty {
                        try await syncer.deleteCalendars(deletedIds)
                    }

                    let records = items
                        .filter { $0.deleted != true }
                        .compactMap { Self.calendarRecord(from: $0, accountId: accountID) }
                    if !records.isEmpty {
                        try await syncer.upsertCalendars(records)
                    }

                    if let newToken = response.nextSyncToken {
                        calendarListSyncToken = newToken
                    }
                } catch CalendarAPIError.gone {
                    // Sync token expired — fall back to full fetch
                    Self.logger.warning("Calendar list sync token expired, performing full fetch")
                    calendarListSyncToken = nil
                    await syncCalendarList()
                }
            } else {
                // Full fetch — no sync token available yet
                let (calendars, listSyncToken) = try await listService.listCalendars(accountID: accountID)
                let records = calendars.compactMap { Self.calendarRecord(from: $0, accountId: accountID) }
                try await syncer.upsertCalendars(records)
                calendarListSyncToken = listSyncToken
            }
        } catch {
            Self.logger.error("Calendar list sync failed: \(String(describing: error))")
        }
    }

    // MARK: - Conversion Helpers

    /// Converts a `CalendarAPICalendarListEntry` to a `CalendarRecord`.
    /// Returns nil if the entry has no ID.
    nonisolated private static func calendarRecord(
        from entry: CalendarAPICalendarListEntry,
        accountId: String
    ) -> CalendarRecord? {
        guard let calendarId = entry.id else { return nil }
        return CalendarRecord(
            calendarId: calendarId,
            accountId: accountId,
            summary: entry.summary ?? calendarId,
            description: entry.description,
            timeZone: entry.timeZone,
            backgroundColor: entry.backgroundColor ?? "#3A6FF0",
            foregroundColor: entry.foregroundColor ?? "#FFFFFF",
            isPrimary: entry.primary ?? false,
            accessRole: entry.accessRole ?? "reader",
            isVisible: !(entry.hidden ?? false),
            summaryOverride: entry.summaryOverride,
            syncToken: nil,
            lastSyncedAt: nil
        )
    }

    /// Converts API events into database records for events and attendees.
    /// `calendarTimeZone` is forwarded to `parseDateTime` for correct all-day event handling.
    nonisolated static func convertToRecords(
        events: [CalendarAPIEvent],
        calendarId: String,
        accountId: String,
        calendarTimeZone: String? = nil
    ) -> ([CalendarEventRecord], [CalendarAttendeeRecord]) {
        var eventRecords: [CalendarEventRecord] = []
        var attendeeRecords: [CalendarAttendeeRecord] = []

        for event in events {
            guard let eventId = event.id else { continue }
            let startTime = event.start.map { parseDateTime($0, calendarTimeZone: calendarTimeZone) } ?? Date().timeIntervalSince1970
            let endTime = event.end.map { parseDateTime($0, calendarTimeZone: calendarTimeZone) } ?? Date().timeIntervalSince1970
            let isAllDay = event.start?.date != nil

            let record = CalendarEventRecord(
                eventId: eventId,
                calendarId: calendarId,
                accountId: accountId,
                summary: event.summary,
                description: event.description,
                location: event.location,
                startTime: startTime,
                endTime: endTime,
                isAllDay: isAllDay,
                timeZone: event.start?.timeZone ?? event.end?.timeZone,
                status: event.status ?? "confirmed",
                organizerEmail: event.organizer?.email,
                organizerName: event.organizer?.displayName,
                organizerIsSelf: event.organizer?.isSelf ?? false,
                creatorEmail: event.creator?.email,
                selfResponseStatus: findSelfAttendeeStatus(event.attendees),
                colorId: event.colorId,
                isRecurring: event.recurringEventId != nil || event.recurrence != nil,
                recurringEventId: event.recurringEventId,
                conferenceLink: findConferenceLink(event.conferenceData),
                conferenceName: event.conferenceData?.conferenceSolution?.name,
                eventType: event.eventType ?? "default",
                etag: event.etag ?? "",
                htmlLink: event.htmlLink,
                canEdit: (event.organizer?.isSelf ?? false) || (event.guestsCanModify ?? false),
                iCalUid: event.iCalUID,
                sequence: event.sequence,
                remindersJson: encodeJSON(event.reminders),
                attachmentsJson: encodeJSON(event.attachments),
                extendedPropertiesJson: encodeJSON(event.extendedProperties),
                updatedAt: parseRFC3339(event.updated) ?? Date().timeIntervalSince1970
            )
            eventRecords.append(record)

            for attendee in event.attendees ?? [] {
                guard let email = attendee.email else { continue }
                let attendeeRecord = CalendarAttendeeRecord(
                    eventId: eventId,
                    calendarId: calendarId,
                    accountId: accountId,
                    email: email,
                    displayName: attendee.displayName,
                    responseStatus: attendee.responseStatus ?? "needsAction",
                    isOrganizer: attendee.organizer ?? false,
                    isResource: attendee.resource ?? false,
                    isOptional: attendee.optional ?? false
                )
                attendeeRecords.append(attendeeRecord)
            }
        }

        return (eventRecords, attendeeRecords)
    }

    // MARK: - Date Parsing

    /// Thread-safe ISO8601 strategy with fractional seconds.
    /// `Date.ISO8601FormatStyle` is a value type — safe to use from any isolation context.
    nonisolated private static let iso8601WithFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Thread-safe ISO8601 strategy without fractional seconds.
    nonisolated private static let iso8601Standard = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// Gregorian calendar for date-component parsing — Google Calendar dates always assume Gregorian.
    nonisolated private static let gregorianCalendar = Calendar(identifier: .gregorian)

    /// Parses a `CalendarAPIDateTime` into a Unix timestamp.
    /// For all-day events, `calendarTimeZone` is used as the fallback when the event itself
    /// has no timezone — prevents incorrect date display in negative-UTC timezones.
    nonisolated private static func parseDateTime(
        _ dt: CalendarAPIDateTime,
        calendarTimeZone: String? = nil
    ) -> Double {
        if let dateTime = dt.dateTime {
            if let date = try? iso8601WithFractional.parse(dateTime) {
                return date.timeIntervalSince1970
            }
            // Retry without fractional seconds
            if let date = try? iso8601Standard.parse(dateTime) {
                return date.timeIntervalSince1970
            }
            return Date().timeIntervalSince1970
        } else if let dateStr = dt.date {
            // All-day event: "yyyy-MM-dd" — parse via DateComponents (allocation-free, thread-safe)
            let parts = dateStr.split(separator: "-")
            guard parts.count == 3,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let day = Int(parts[2]) else {
                return Date().timeIntervalSince1970
            }
            var dc = DateComponents()
            dc.year = year
            dc.month = month
            dc.day = day
            let tzIdentifier = dt.timeZone ?? calendarTimeZone ?? "UTC"
            dc.timeZone = TimeZone(identifier: tzIdentifier) ?? .gmt
            return gregorianCalendar.date(from: dc)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        }
        return Date().timeIntervalSince1970
    }

    /// Parses an RFC3339 string into a Unix timestamp.
    nonisolated private static func parseRFC3339(_ str: String?) -> Double? {
        guard let str else { return nil }
        if let date = try? iso8601WithFractional.parse(str) { return date.timeIntervalSince1970 }
        if let date = try? iso8601Standard.parse(str) { return date.timeIntervalSince1970 }
        return nil
    }

    /// Finds the response status for the self attendee.
    nonisolated private static func findSelfAttendeeStatus(_ attendees: [CalendarAPIAttendee]?) -> String? {
        attendees?.first(where: { $0.isSelf == true })?.responseStatus
    }

    /// Extracts the video conference link from conference data.
    nonisolated private static func findConferenceLink(_ data: CalendarAPIConferenceData?) -> String? {
        data?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri
    }

    /// Encodes an `Encodable` value to a JSON string.
    nonisolated private static func encodeJSON<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
