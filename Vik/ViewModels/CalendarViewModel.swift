import SwiftUI
import Foundation
internal import GRDB
private import os

@Observable
@MainActor
final class CalendarViewModel {

    // MARK: - State

    var viewMode: CalendarViewMode = .month
    var selectedDate: Date = .now
    var events: [CalendarEvent] = []
    var calendars: [CalendarInfo] = []
    var isLoading = false
    var error: CalendarAPIError?
    var selectedEvent: CalendarEvent?

    /// Set of composite IDs ("\(accountID)\u{001F}\(calendarId)") using Unit Separator for unified multi-account view.
    var visibleCalendarIDs: Set<String> = []

    /// Cached week interval for the current `selectedDate`. Updated whenever `selectedDate` changes.
    private(set) var selectedWeek: DateInterval = {
        let cal = Calendar.current
        let now = Date.now
        return cal.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: cal.startOfDay(for: now), end: cal.startOfDay(for: now).addingTimeInterval(7 * 86400))
    }()

    /// Events grouped by start-of-day key. Updated whenever `events` changes.
    private(set) var eventsByDay: [Date: [CalendarEvent]] = [:]

    /// Events spanning more than one calendar day (multi-day or all-day). Updated whenever `events` changes.
    private(set) var multiDayEvents: [CalendarEvent] = []

    /// Called after any successful event mutation (create, update, delete, RSVP, quick-add).
    @ObservationIgnored var onEventMutated: (() async -> Void)?

    // MARK: - Dependencies

    let db: MailDatabase
    private let eventService = CalendarEventService.shared
    private let listService = CalendarListService.shared
    nonisolated private static let logger = Logger(category: "CalendarViewModel")

    // MARK: - Reactive Observation

    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var calendarObservationTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var lastObservedRange: DateInterval?
    @ObservationIgnored private var lastObservedCalendarKeys: Set<String>?
    /// Cached calendar ID → color map, rebuilt only when `calendars` changes.
    @ObservationIgnored private var calendarColorMap: [String: Color] = [:]

    // MARK: - Init

    init(db: MailDatabase) {
        self.db = db
    }

    isolated deinit {
        observationTask?.cancel()
        calendarObservationTask?.cancel()
        debounceTask?.cancel()
    }

    // MARK: - Observation

    /// Starts observing both calendars and events tables. Call once from `.task { }` in the view.
    func startObserving() {
        lastObservedRange = nil
        lastObservedCalendarKeys = nil
        observeCalendars()
        observeEvents()
    }

    /// Lightweight projection of CalendarRecord excluding sync_token and last_synced_at.
    /// Conforms to Equatable so `removeDuplicates()` can filter out observation notifications
    /// triggered by sync metadata writes that don't affect the UI.
    private struct CalendarSnapshot: Decodable, FetchableRecord, Equatable {
        var calendarId: String
        var accountId: String
        var summary: String
        var description: String?
        var timeZone: String?
        var backgroundColor: String
        var foregroundColor: String
        var isPrimary: Bool
        var accessRole: String
        var isVisible: Bool
        var summaryOverride: String?

        static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase

        func toCalendarInfo() -> CalendarInfo {
            CalendarInfo(
                id: "\(accountId)_\(calendarId)",
                calendarId: calendarId,
                accountID: accountId,
                summary: summary,
                description: description,
                timeZone: timeZone,
                backgroundColor: backgroundColor,
                foregroundColor: foregroundColor,
                isPrimary: isPrimary,
                accessRole: CalendarInfo.AccessRole(rawValue: accessRole) ?? .reader,
                isVisible: isVisible,
                summaryOverride: summaryOverride
            )
        }
    }

    private func observeCalendars() {
        calendarObservationTask?.cancel()
        let dbPool = db.dbPool
        // Select only UI-relevant columns to avoid triggering on sync_token / last_synced_at writes.
        let calendarObservation = ValueObservation.tracking { db in
            try CalendarSnapshot.fetchAll(db, sql: """
                SELECT calendar_id, account_id, summary, description, time_zone,
                       background_color, foreground_color, is_primary, access_role,
                       is_visible, summary_override
                FROM calendars
                ORDER BY is_primary DESC, summary ASC
            """)
        }
        .removeDuplicates()
        calendarObservationTask = Task { @MainActor [weak self] in
            do {
                for try await snapshots in calendarObservation.values(in: dbPool) {
                    guard let self else { return }
                    self.calendars = snapshots.map { $0.toCalendarInfo() }
                    self.calendarColorMap = self.calendars.reduce(into: [:]) { map, cal in
                        map[cal.calendarId] = Color(hex: cal.backgroundColor)
                    }
                    let newVisibleIDs = Set(
                        snapshots.filter(\.isVisible).map { "\($0.accountId)\u{001F}\($0.calendarId)" }
                    )
                    let changed = newVisibleIDs != self.visibleCalendarIDs
                    self.visibleCalendarIDs = newVisibleIDs
                    if changed {
                        self.refreshObservation()
                    }
                }
            } catch is CancellationError {
                // Normal task cancellation — not an error
            } catch {
                Self.logger.error("Calendar observation failed: \(error.localizedDescription)")
            }
        }
    }

    private func observeEvents() {
        let dateRange = currentDateRange
        let visibleIDs = visibleCalendarIDs

        // Skip re-observation if parameters haven't changed
        if dateRange == lastObservedRange, visibleIDs == lastObservedCalendarKeys {
            return
        }
        lastObservedRange = dateRange
        lastObservedCalendarKeys = visibleIDs

        observationTask?.cancel()
        // Decode composite "accountId\u{001F}calendarId" keys into typed tuples so the
        // DB query can scope each calendar to its owning account — preventing
        // cross-account matches on shared calendar IDs.
        let calendarKeys: [(calendarId: String, accountId: String)] = visibleIDs.compactMap { id in
            let parts = id.split(separator: "\u{001F}", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (calendarId: String(parts[1]), accountId: String(parts[0]))
        }
        guard !calendarKeys.isEmpty else {
            events = []
            recomputeEventCaches()
            return
        }
        let start = dateRange.start.timeIntervalSince1970
        let end = dateRange.end.timeIntervalSince1970
        let observation = ValueObservation.tracking { db in
            try MailDatabaseQueries.eventsWithAttendeesForDateRange(
                calendarKeys: calendarKeys,
                start: start,
                end: end,
                in: db
            )
        }
        let dbPool = db.dbPool
        observationTask = Task { @MainActor [weak self] in
            do {
                for try await records in observation.values(in: dbPool) {
                    guard let self else { return }
                    self.debounceTask?.cancel()
                    self.debounceTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled, let self else { return }
                        let colorMap = self.calendarColorMap
                        let capturedRecords = records
                        let enriched = await Task.detached {
                            Self.enrichRecordsOffActor(capturedRecords, colorMap: colorMap)
                        }.value
                        guard !Task.isCancelled else { return }
                        let caches = await Task.detached {
                            Self.computeEventCaches(enriched)
                        }.value
                        guard !Task.isCancelled else { return }
                        self.events = enriched
                        self.eventsByDay = caches.eventsByDay
                        self.multiDayEvents = caches.multiDay
                    }
                }
            } catch is CancellationError {
                // Normal task cancellation — not an error
            } catch {
                Self.logger.error("Event observation failed: \(error.localizedDescription)")
            }
        }
    }

    /// Re-observes events when the date range or visible calendars change.
    func refreshObservation() {
        observeEvents()
    }

    // MARK: - Navigation

    func navigateForward() {
        let calendar = Calendar.current
        switch viewMode {
        case .month:
            selectedDate = calendar.date(byAdding: .month, value: 1, to: selectedDate) ?? selectedDate
        case .week:
            selectedDate = calendar.date(byAdding: .weekOfYear, value: 1, to: selectedDate) ?? selectedDate
        case .day:
            selectedDate = calendar.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
        case .agenda:
            selectedDate = calendar.date(byAdding: .weekOfYear, value: 1, to: selectedDate) ?? selectedDate
        }
        recomputeSelectedWeek()
        refreshObservation()
    }

    func navigateBackward() {
        let calendar = Calendar.current
        switch viewMode {
        case .month:
            selectedDate = calendar.date(byAdding: .month, value: -1, to: selectedDate) ?? selectedDate
        case .week:
            selectedDate = calendar.date(byAdding: .weekOfYear, value: -1, to: selectedDate) ?? selectedDate
        case .day:
            selectedDate = calendar.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
        case .agenda:
            selectedDate = calendar.date(byAdding: .weekOfYear, value: -1, to: selectedDate) ?? selectedDate
        }
        recomputeSelectedWeek()
        refreshObservation()
    }

    func goToToday() {
        selectedDate = .now
        recomputeSelectedWeek()
        refreshObservation()
    }

    func selectDate(_ date: Date) {
        selectedDate = date
        recomputeSelectedWeek()
        refreshObservation()
    }

    // MARK: - Calendar Toggles

    func toggleCalendarVisibility(_ calendar: CalendarInfo) async {
        do {
            try await db.dbPool.write { db in
                try MailDatabaseQueries.updateCalendarVisibility(
                    calendarId: calendar.calendarId,
                    accountId: calendar.accountID,
                    isVisible: !calendar.isVisible,
                    in: db
                )
            }
            // visibleCalendarIDs updates via calendar observation
        } catch {
            Self.logger.error("Failed to toggle calendar visibility: \(error.localizedDescription)")
        }
    }

    // MARK: - CRUD

    func createEvent(_ input: CalendarAPIEventInput, calendarId: String, accountID: String) async throws {
        error = nil
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await eventService.insertEvent(
                calendarId: calendarId,
                event: input,
                accountID: accountID
            )
            // Sync engine will pick up the new event via incremental sync.
        } catch CalendarAPIError.offline {
            await CalendarOfflineActionQueue.shared.enqueue(.init(
                id: UUID(),
                accountID: accountID,
                createdAt: .now,
                actionType: .createEvent(calendarId: calendarId, input: input)
            ))
            ToastManager.shared.show(message: "Event queued (will sync when online)")
        } catch {
            self.error = error
            throw error
        }
        await onEventMutated?()
    }

    func updateEvent(_ event: CalendarEvent, input: CalendarAPIEventInput) async throws {
        try await updateEvent(
            calendarId: event.calendarId,
            eventId: event.googleEventId,
            accountID: event.accountID,
            etag: event.etag,
            input: input
        )
    }

    func updateEvent(calendarId: String, eventId: String, accountID: String, etag: String?, input: CalendarAPIEventInput) async throws {
        error = nil
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await eventService.updateEvent(
                calendarId: calendarId,
                eventId: eventId,
                event: input,
                accountID: accountID,
                etag: etag
            )
        } catch CalendarAPIError.offline {
            await CalendarOfflineActionQueue.shared.enqueue(.init(
                id: UUID(),
                accountID: accountID,
                createdAt: .now,
                actionType: .updateEvent(
                    calendarId: calendarId,
                    eventId: eventId,
                    input: input,
                    etag: etag ?? ""
                )
            ))
            ToastManager.shared.show(message: "Event queued (will sync when online)")
        } catch {
            self.error = error
            throw error
        }
        await onEventMutated?()
    }

    func deleteEvent(_ event: CalendarEvent) async throws {
        error = nil
        isLoading = true
        defer { isLoading = false }

        // Snapshot and delete atomically in one write transaction.
        let snapshot: (CalendarEventRecord, [CalendarAttendeeRecord])?
        do {
            snapshot = try await db.dbPool.write { db in
                guard let eventRecord = try CalendarEventRecord
                    .filter(Column("event_id") == event.googleEventId
                        && Column("calendar_id") == event.calendarId
                        && Column("account_id") == event.accountID)
                    .fetchOne(db)
                else { return nil }
                let attendees = try CalendarAttendeeRecord
                    .filter(Column("event_id") == event.googleEventId
                        && Column("calendar_id") == event.calendarId
                        && Column("account_id") == event.accountID)
                    .fetchAll(db)
                // Delete event — attendees cascade automatically via ON DELETE CASCADE.
                try db.execute(
                    sql: "DELETE FROM calendar_events WHERE event_id = ? AND calendar_id = ? AND account_id = ?",
                    arguments: [event.googleEventId, event.calendarId, event.accountID]
                )
                return (eventRecord, attendees)
            }
        } catch {
            self.error = CalendarAPIError.wrap(error)
            return
        }

        do {
            try await eventService.deleteEvent(
                calendarId: event.calendarId,
                eventId: event.googleEventId,
                accountID: event.accountID
            )
        } catch CalendarAPIError.offline {
            await CalendarOfflineActionQueue.shared.enqueue(.init(
                id: UUID(),
                accountID: event.accountID,
                createdAt: .now,
                actionType: .deleteEvent(calendarId: event.calendarId, eventId: event.googleEventId)
            ))
            ToastManager.shared.show(message: "Event queued (will sync when online)")
        } catch {
            // Rollback: re-insert the deleted records.
            if let (eventRecord, attendees) = snapshot {
                do {
                    try await db.dbPool.write { db in
                        try eventRecord.insert(db)
                        for attendee in attendees { try attendee.insert(db) }
                    }
                } catch {
                    Self.logger.error("Rollback re-insert failed after deleteEvent API error: \(error.localizedDescription)")
                }
            }
            self.error = error
            throw error
        }
        await onEventMutated?()
    }

    func respondToEvent(_ event: CalendarEvent, status: CalendarRSVPStatus) async throws {
        error = nil
        isLoading = true
        defer { isLoading = false }
        // Save original status for rollback.
        let previousStatus = event.selfResponseStatus
        // Optimistic local update regardless of connectivity.
        do {
            try await db.dbPool.write { db in
                try db.execute(
                    sql: """
                        UPDATE calendar_events SET self_response_status = ?
                        WHERE event_id = ? AND calendar_id = ? AND account_id = ?
                        """,
                    arguments: [status.rawValue, event.googleEventId, event.calendarId, event.accountID]
                )
            }
        } catch {
            Self.logger.error("Optimistic RSVP update failed: \(error.localizedDescription)")
        }
        do {
            _ = try await eventService.respondToEvent(
                calendarId: event.calendarId,
                eventId: event.googleEventId,
                accountID: event.accountID,
                status: status.rawValue
            )
        } catch CalendarAPIError.offline {
            await CalendarOfflineActionQueue.shared.enqueue(.init(
                id: UUID(),
                accountID: event.accountID,
                createdAt: .now,
                actionType: .rsvpEvent(calendarId: event.calendarId, eventId: event.googleEventId, status: status.rawValue)
            ))
            ToastManager.shared.show(message: "Event queued (will sync when online)")
        } catch {
            // Rollback: restore previous RSVP status.
            do {
                try await db.dbPool.write { db in
                    try db.execute(
                        sql: """
                            UPDATE calendar_events SET self_response_status = ?
                            WHERE event_id = ? AND calendar_id = ? AND account_id = ?
                            """,
                        arguments: [previousStatus.rawValue, event.googleEventId, event.calendarId, event.accountID]
                    )
                }
            } catch {
                Self.logger.error("Rollback of RSVP status failed: \(error.localizedDescription)")
            }
            self.error = error
            throw error
        }
        await onEventMutated?()
    }

    func quickAddEvent(text: String, calendarId: String, accountID: String) async throws {
        error = nil
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await eventService.quickAdd(
                calendarId: calendarId,
                text: text,
                accountID: accountID
            )
        } catch {
            self.error = error
            throw error
        }
        await onEventMutated?()
    }

    // MARK: - Helpers

    func eventsForDay(_ date: Date) -> [CalendarEvent] {
        let start = Calendar.current.startOfDay(for: date)
        return eventsByDay[start] ?? []
    }

    // MARK: - Private

    private func recomputeSelectedWeek() {
        let cal = Calendar.current
        selectedWeek = cal.dateInterval(of: .weekOfYear, for: selectedDate)
            ?? DateInterval(start: cal.startOfDay(for: selectedDate), end: cal.startOfDay(for: selectedDate).addingTimeInterval(7 * 86400))
    }

    private func recomputeEventCaches() {
        let cal = Calendar.current
        var dict: [Date: [CalendarEvent]] = [:]
        var multiDay: [CalendarEvent] = []
        for event in events {
            var day = cal.startOfDay(for: event.startTime)
            let startDay = day
            let rawEndDay = cal.startOfDay(for: event.endTime)
            let endDay: Date
            if event.endTime == rawEndDay && rawEndDay > startDay {
                guard let adjusted = cal.date(byAdding: .day, value: -1, to: rawEndDay) else { continue }
                endDay = adjusted
            } else {
                endDay = rawEndDay
            }
            while day <= endDay {
                dict[day, default: []].append(event)
                guard let nextDay = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = nextDay
            }
            if event.isAllDay || cal.startOfDay(for: event.startTime) != cal.startOfDay(for: event.endTime) {
                multiDay.append(event)
            }
        }
        // Pre-sort each day's events so views don't need to sort on render
        for key in dict.keys {
            dict[key]?.sort { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.startTime < rhs.startTime
            }
        }
        eventsByDay = dict
        multiDayEvents = multiDay
    }

    /// The date range for the current view mode, used to scope the DB query.
    private var currentDateRange: DateInterval {
        let calendar = Calendar.current
        switch viewMode {
        case .month:
            let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate))
                ?? selectedDate
            let weekday = calendar.component(.weekday, from: firstOfMonth)
            let firstWeekdayOffset = (weekday - calendar.firstWeekday + 7) % 7
            let gridStart = calendar.date(byAdding: .day, value: -firstWeekdayOffset, to: firstOfMonth)
                ?? firstOfMonth
            let gridEnd = calendar.date(byAdding: .day, value: 42, to: gridStart)
                ?? gridStart
            return DateInterval(start: gridStart, end: gridEnd)
        case .week:
            return selectedWeek
        case .day:
            let start = calendar.startOfDay(for: selectedDate)
            let end = calendar.date(byAdding: .day, value: 1, to: start)
                ?? start
            return DateInterval(start: start, end: end)
        case .agenda:
            let start = calendar.startOfDay(for: selectedDate)
            let end = calendar.date(byAdding: .day, value: 30, to: start)
                ?? start
            return DateInterval(start: start, end: end)
        }
    }

    /// Enriches event records with attendee data and resolved colors.
    private func enrichRecords(_ records: [EventWithAttendees]) -> [CalendarEvent] {
        guard !records.isEmpty else { return [] }

        // Use cached color map (rebuilt when calendars change, not per-enrichment).
        let colorMap = calendarColorMap

        return records.compactMap { item in
            let calendarColor = colorMap[item.calendarEventRecord.calendarId] ?? BrandColor.blue
            return item.calendarEventRecord.toCalendarEvent(
                attendees: item.attendees,
                calendarColor: calendarColor
            )
        }
    }

    // MARK: - Off-Actor Computation

    nonisolated private static func enrichRecordsOffActor(_ records: [EventWithAttendees], colorMap: [String: Color]) -> [CalendarEvent] {
        guard !records.isEmpty else { return [] }
        return records.compactMap { item in
            let calendarColor = colorMap[item.calendarEventRecord.calendarId] ?? BrandColor.blue
            return item.calendarEventRecord.toCalendarEvent(
                attendees: item.attendees,
                calendarColor: calendarColor
            )
        }
    }

    nonisolated private static func computeEventCaches(_ events: [CalendarEvent]) -> (eventsByDay: [Date: [CalendarEvent]], multiDay: [CalendarEvent]) {
        let cal = Calendar.current
        var dict: [Date: [CalendarEvent]] = [:]
        var multiDay: [CalendarEvent] = []
        for event in events {
            var day = cal.startOfDay(for: event.startTime)
            let startDay = day
            let rawEndDay = cal.startOfDay(for: event.endTime)
            let endDay: Date
            if event.endTime == rawEndDay && rawEndDay > startDay {
                guard let adjusted = cal.date(byAdding: .day, value: -1, to: rawEndDay) else { continue }
                endDay = adjusted
            } else {
                endDay = rawEndDay
            }
            while day <= endDay {
                dict[day, default: []].append(event)
                guard let nextDay = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = nextDay
            }
            if event.isAllDay || cal.startOfDay(for: event.startTime) != cal.startOfDay(for: event.endTime) {
                multiDay.append(event)
            }
        }
        for key in dict.keys {
            dict[key]?.sort { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.startTime < rhs.startTime
            }
        }
        return (eventsByDay: dict, multiDay: multiDay)
    }
}
