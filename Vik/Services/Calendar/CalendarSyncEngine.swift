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
        case error(GoogleAPIError)
    }

    private(set) var state: State = .idle
    let accountID: String

    // MARK: - Dependencies

    private let db: MailDatabase
    private let syncer: CalendarBackgroundSyncer
    private let eventService: any CalendarEventFetching
    private let listService: any CalendarListReading

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
    private var triggeredSyncTask: Task<Void, Never>?

    /// Pre-tightening polling interval, restored after the post-edit window expires.
    private var preEditInterval: TimeInterval?

    /// Sync token for incremental calendar list sync via `CalendarListService.syncCalendars`.
    private var calendarListSyncToken: String?

    /// Reentrancy guard: prevents overlapping `syncIncremental()` runs.
    /// The polling loop and user-triggered `triggerSync()` can both call
    /// `syncIncremental()` — actor reentrancy allows the second call to start
    /// while the first is suspended at an `await`. This flag is set/cleared
    /// synchronously (no `await` between check and set), so it's actor-safe.
    // Shared reentrancy guard pattern — also in FullSyncEngine
    private var isSyncingIncrementally = false

    deinit {
        syncTask?.cancel()
        calendarListSyncTask?.cancel()
        postEditRevertTask?.cancel()
        triggeredSyncTask?.cancel()
    }

    // MARK: - Init

    /// - Note: `@MainActor` required because `eventService` and `listService`
    /// are `@MainActor` singletons accessed via `.shared` in the init body.
    @MainActor init(
        accountID: String,
        db: MailDatabase,
        eventService: any CalendarEventFetching = CalendarEventService.shared,
        listService: any CalendarListReading = CalendarListService.shared
    ) {
        self.accountID = accountID
        self.db = db
        self.syncer = CalendarBackgroundSyncer(db: db)
        self.eventService = eventService
        self.listService = listService
    }

    // MARK: - Lifecycle

    /// Starts the calendar sync lifecycle.
    /// Performs initial sync if no sync tokens exist, then starts incremental polling.
    func start() async {
        guard syncTask == nil else { return }

        // Capture immutable values for use inside the Task closure
        let db = self.db
        let accountID = self.accountID

        // Assign syncTask BEFORE any async work so stop() can cancel it immediately,
        // including if stop() is called during performInitialSync().
        // The incremental polling loop runs inside this same task (not via
        // startIncrementalLoop, which would overwrite syncTask).
        syncTask = Task {
            // Restore persisted calendar list sync token
            self.calendarListSyncToken = try? await db.dbPool.read { db in
                try MailDatabaseQueries.syncState(in: db)?.calendarListSyncToken
            }

            let hasTokens = (try? await db.dbPool.read { db in
                try CalendarRecord
                    .filter(Column("account_id") == accountID)
                    .filter(Column("sync_token") != nil)
                    .fetchCount(db) > 0
            }) ?? true  // Default to "already synced" on DB read failure — prevents spurious full resync

            if !hasTokens {
                await self.performInitialSync()
            }

            guard !Task.isCancelled else { return }

            // Kick off the calendar list loop on its own task
            self.startCalendarListSyncLoop()

            // Run the incremental polling loop inline so cancellation of syncTask
            // propagates directly to this loop (rather than being a separate task)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.pollingInterval))
                guard !Task.isCancelled else { break }
                await self.syncIncremental()
            }
        }
    }

    /// Stops all sync tasks, awaiting in-flight work so that
    /// `CalendarBackgroundSyncer` DB writes complete before the engine is discarded.
    func stop() async {
        // Snapshot all refs before any await to prevent reentrancy from creating new tasks
        // between cancel and nil-out (mirrors FullSyncEngine pattern)
        let snap = (
            sync: syncTask,
            calList: calendarListSyncTask,
            postEdit: postEditRevertTask,
            triggered: triggeredSyncTask
        )
        syncTask = nil
        calendarListSyncTask = nil
        postEditRevertTask = nil
        triggeredSyncTask = nil

        snap.sync?.cancel()
        snap.calList?.cancel()
        snap.postEdit?.cancel()
        snap.triggered?.cancel()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await snap.sync?.value }
            group.addTask { await snap.calList?.value }
            group.addTask { await snap.postEdit?.value }
            group.addTask { await snap.triggered?.value }
        }

        state = .idle
    }

    /// Triggers an immediate incremental sync (e.g., after an event edit).
    func triggerSync() {
        triggeredSyncTask?.cancel()
        triggeredSyncTask = Task {
            guard !Task.isCancelled else { return }
            await syncIncremental()
        }
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
    /// Reverts to the pre-edit polling interval after 120 seconds.
    func temporarilyTightenPolling() {
        if preEditInterval == nil {
            preEditInterval = pollingInterval
        }
        pollingInterval = Self.postEditInterval
        postEditRevertTask?.cancel()
        postEditRevertTask = Task {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self.pollingInterval = self.preEditInterval ?? Self.calendarActiveInterval
            self.preEditInterval = nil
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
            await persistCalendarListSyncToken(listSyncToken)

            // 2. For each visible calendar: fetch events (-30d to +90d)
            let now = Date()
            let calendar = Calendar.current
            let timeMin = calendar.date(byAdding: .day, value: -30, to: now) ?? now.addingTimeInterval(-30 * 86400)
            let timeMax = calendar.date(byAdding: .day, value: 90, to: now) ?? now.addingTimeInterval(90 * 86400)

            let visibleCalendars = records.filter { $0.isVisible }
            var failCount = 0
            try await withThrowingTaskGroup(of: Bool.self) { group in
                var inFlight = 0
                let maxConcurrency = 3

                for calendar in visibleCalendars {
                    guard !Task.isCancelled else { break }

                    if inFlight >= maxConcurrency {
                        if let succeeded = try await group.next() {
                            if !succeeded { failCount += 1 }
                        }
                        inFlight -= 1
                    }

                    let calId = calendar.calendarId
                    let calTZ = calendar.timeZone
                    // self capture is intentional — actor lifecycle is managed by stop() which cancels syncTask
                    group.addTask {
                        do {
                            try await self.syncFullEvents(
                                calendarId: calId,
                                timeMin: timeMin,
                                timeMax: timeMax,
                                calendarTimeZone: calTZ
                            )
                            return true
                        } catch {
                            Self.logger.warning("Initial sync failed for calendar \(calId): \(String(describing: error))")
                            return false
                        }
                    }
                    inFlight += 1
                }

                // Drain remaining tasks
                for try await succeeded in group {
                    if !succeeded { failCount += 1 }
                }
            }

            let totalCalendars = visibleCalendars.count
            if failCount == totalCalendars && totalCalendars > 0 {
                state = .error(GoogleAPIError.httpError(0, Data()))
                Self.logger.error("Initial sync failed for all \(totalCalendars) calendars")
                return
            }

            state = .idle
        } catch let error as GoogleAPIError {
            state = .error(error)
            Self.logger.error("Initial calendar sync failed: \(String(describing: error))")
        } catch {
            state = .error(.networkError(error))
            Self.logger.error("Initial calendar sync failed: \(String(describing: error))")
        }
    }

    /// Full event fetch for a single calendar with pagination, storing the sync token.
    /// Writes each page to the DB as it arrives to avoid accumulating all events in memory.
    private func syncFullEvents(calendarId: String, timeMin: Date, timeMax: Date, calendarTimeZone: String? = nil) async throws {
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
            let pageEvents = response.items ?? []
            if !pageEvents.isEmpty {
                let (pageRecords, pageAttendees) = Self.convertToRecords(
                    events: pageEvents, calendarId: calendarId, accountId: accountID,
                    calendarTimeZone: calendarTimeZone
                )
                try await syncer.upsertEvents(pageRecords, attendees: pageAttendees)
            }
            pageToken = response.nextPageToken
            if response.nextSyncToken != nil { syncToken = response.nextSyncToken }
            // Pace pagination requests to avoid 429s
            if pageToken != nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
        } while pageToken != nil

        if let syncToken {
            try await syncer.updateSyncToken(
                calendarId: calendarId, accountId: accountID, token: syncToken
            )
        }
    }

    // MARK: - Incremental Sync

    /// Result of fetching incremental changes for a single calendar.
    /// Produced off-actor by the task group, consumed on-actor for DB writes.
    private enum IncrementalFetchResult: Sendable {
        case success(
            calendarId: String,
            calendarTimeZone: String?,
            cancelled: [CalendarAPIEvent],
            active: [CalendarAPIEvent],
            syncToken: String?
        )
        case gone(calendarId: String, calendarTimeZone: String?)
        case failed(calendarId: String, errorDescription: String)
    }

    private func syncIncremental() async {
        if case .initialSync = state { return }
        guard NetworkMonitor.isReachable else { return }
        guard !isSyncingIncrementally else { return }
        isSyncingIncrementally = true
        defer { isSyncingIncrementally = false }
        state = .syncing

        do {
            // Capture actor properties for use in off-actor task group closures
            let eventService = self.eventService
            let accountID = self.accountID

            let calendars = try await db.dbPool.read { db in
                try MailDatabaseQueries.visibleCalendars(accountId: accountID, in: db)
            }

            let syncableCalendars = calendars.filter { calendar in
                guard let token = calendar.syncToken else { return false }
                return !token.isEmpty
            }

            // Fetch incremental changes in parallel (max 3 concurrent)
            let results: [IncrementalFetchResult] = await withTaskGroup(of: IncrementalFetchResult.self) { group in
                var inFlight = 0
                let maxConcurrency = 3
                var collected: [IncrementalFetchResult] = []

                for calendar in syncableCalendars {
                    guard !Task.isCancelled else { break }

                    if inFlight >= maxConcurrency {
                        if let result = await group.next() {
                            collected.append(result)
                            inFlight -= 1
                        }
                    }

                    let calId = calendar.calendarId
                    let calTZ = calendar.timeZone
                    let syncToken = calendar.syncToken!
                    group.addTask {
                        await Self.fetchIncrementalChanges(
                            calendarId: calId,
                            calendarTimeZone: calTZ,
                            syncToken: syncToken,
                            accountID: accountID,
                            eventService: eventService
                        )
                    }
                    inFlight += 1
                }

                // Drain remaining tasks
                for await result in group {
                    collected.append(result)
                }
                return collected
            }

            // Process results on-actor (DB writes, sync token updates, 410 recovery)
            for result in results {
                switch result {
                case .success(let calendarId, let calendarTimeZone, let cancelled, let active, let syncToken):
                    if !cancelled.isEmpty {
                        let deleteIds = cancelled.compactMap { event -> (eventId: String, calendarId: String, accountId: String)? in
                            guard let id = event.id else { return nil }
                            return (eventId: id, calendarId: calendarId, accountId: accountID)
                        }
                        try await syncer.deleteEvents(deleteIds)
                    }

                    if !active.isEmpty {
                        let (eventRecords, attendeeRecords) = Self.convertToRecords(
                            events: active, calendarId: calendarId, accountId: accountID,
                            calendarTimeZone: calendarTimeZone
                        )
                        try await syncer.upsertEvents(eventRecords, attendees: attendeeRecords)
                    }

                    if let syncToken {
                        try await syncer.updateSyncToken(
                            calendarId: calendarId, accountId: accountID, token: syncToken
                        )
                    }

                case .gone(let calendarId, let calendarTimeZone):
                    // SyncToken expired — clear stale events and trigger full resync for this calendar
                    // Per Google Calendar API 410 spec: wipe local store before full resync
                    // to remove server-side deletions that won't appear in the new full fetch.
                    Self.logger.warning("SyncToken expired for calendar \(calendarId), performing full resync")
                    try? await syncer.deleteEventsForCalendar(
                        calendarId: calendarId, accountId: accountID
                    )
                    let now = Date()
                    let calendar = Calendar.current
                    let timeMin = calendar.date(byAdding: .day, value: -30, to: now) ?? now.addingTimeInterval(-30 * 86400)
                    let timeMax = calendar.date(byAdding: .day, value: 90, to: now) ?? now.addingTimeInterval(90 * 86400)
                    do {
                        try await syncFullEvents(
                            calendarId: calendarId,
                            timeMin: timeMin,
                            timeMax: timeMax,
                            calendarTimeZone: calendarTimeZone
                        )
                    } catch {
                        Self.logger.error("Full resync failed for calendar \(calendarId): \(String(describing: error))")
                    }

                case .failed(let calendarId, let errorDescription):
                    Self.logger.error("Incremental sync failed for calendar \(calendarId): \(errorDescription)")
                }
            }

            state = .idle
            // Refresh calendar reminder notifications after successful sync
            await NotificationService.shared.refreshCalendarReminders(db: db, accountID: accountID)
        } catch {
            state = .error(GoogleAPIError.wrap(error))
            Self.logger.error("Incremental calendar sync failed: \(String(describing: error))")
        }
    }

    /// Fetches incremental changes for a single calendar. Runs off-actor (nonisolated)
    /// so multiple calendars can be fetched concurrently in a task group.
    private nonisolated static func fetchIncrementalChanges(
        calendarId: String,
        calendarTimeZone: String?,
        syncToken: String,
        accountID: String,
        eventService: any CalendarEventFetching
    ) async -> IncrementalFetchResult {
        do {
            var allCancelled: [CalendarAPIEvent] = []
            var allActive: [CalendarAPIEvent] = []
            var pageToken: String? = nil
            var finalSyncToken: String? = nil
            var isFirstPage = true

            // Note: singleEvents is intentionally not passed here. Google's sync token
            // remembers the expansion mode from the initial listEvents(singleEvents: true).
            // Passing it with a syncToken may cause API errors per Google's docs.
            repeat {
                let response = try await eventService.syncEvents(
                    calendarId: calendarId,
                    accountID: accountID,
                    syncToken: isFirstPage ? syncToken : nil,
                    pageToken: pageToken
                )
                isFirstPage = false

                let items = response.items ?? []
                for item in items {
                    if item.status == "cancelled" {
                        allCancelled.append(item)
                    } else {
                        allActive.append(item)
                    }
                }

                pageToken = response.nextPageToken
                if response.nextSyncToken != nil { finalSyncToken = response.nextSyncToken }
            } while pageToken != nil

            return .success(
                calendarId: calendarId,
                calendarTimeZone: calendarTimeZone,
                cancelled: allCancelled,
                active: allActive,
                syncToken: finalSyncToken
            )
        } catch GoogleAPIError.gone {
            return .gone(calendarId: calendarId, calendarTimeZone: calendarTimeZone)
        } catch {
            return .failed(calendarId: calendarId, errorDescription: String(describing: error))
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
                    let (items, newSyncToken) = try await listService.syncCalendars(accountID: accountID, syncToken: token)

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

                    if let newSyncToken {
                        await persistCalendarListSyncToken(newSyncToken)
                    }
                } catch GoogleAPIError.gone {
                    await persistCalendarListSyncToken(nil)
                    Self.logger.info("Calendar list sync token expired, retrying full fetch")
                    // Retry immediately — token is now nil so the full-fetch path runs,
                    // which calls listCalendars() (not syncCalendars) and cannot return 410.
                    await syncCalendarList()
                }
            } else {
                // Full fetch — no sync token available yet
                let (calendars, listSyncToken) = try await listService.listCalendars(accountID: accountID)
                let records = calendars.compactMap { Self.calendarRecord(from: $0, accountId: accountID) }
                try await syncer.upsertCalendars(records)
                await persistCalendarListSyncToken(listSyncToken)
            }
        } catch {
            Self.logger.error("Calendar list sync failed: \(String(describing: error))")
        }
    }

    // MARK: - Calendar List Sync Token Persistence

    /// Persists the calendar list sync token to the account_sync_state table.
    private func persistCalendarListSyncToken(_ token: String?) async {
        calendarListSyncToken = token
        do {
            try await db.dbPool.write { db in
                try MailDatabaseQueries.updateSyncState({ $0.calendarListSyncToken = token }, in: db)
            }
        } catch {
            Self.logger.error("Failed to persist calendar list sync token: \(error.localizedDescription)")
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
            let startTime = event.start.map { parseDateTime($0, calendarTimeZone: calendarTimeZone) } ?? Self.fallbackTimestamp
            let endTime = event.end.map { parseDateTime($0, calendarTimeZone: calendarTimeZone) } ?? Self.fallbackTimestamp
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
                updatedAt: parseRFC3339(event.updated) ?? Self.fallbackTimestamp
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

    /// Sentinel timestamp for unparseable dates — `distantPast` makes bad data obvious instead of silently using "now".
    nonisolated private static let fallbackTimestamp = Date.distantPast.timeIntervalSince1970

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
            return Self.fallbackTimestamp
        } else if let dateStr = dt.date {
            // All-day event: "yyyy-MM-dd" — parse via DateComponents (allocation-free, thread-safe)
            let parts = dateStr.split(separator: "-")
            guard parts.count == 3,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let day = Int(parts[2]) else {
                return Self.fallbackTimestamp
            }
            var dc = DateComponents()
            dc.year = year
            dc.month = month
            dc.day = day
            let tzIdentifier = dt.timeZone ?? calendarTimeZone ?? "UTC"
            dc.timeZone = TimeZone(identifier: tzIdentifier) ?? .gmt
            return gregorianCalendar.date(from: dc)?.timeIntervalSince1970 ?? Self.fallbackTimestamp
        }
        return Self.fallbackTimestamp
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
