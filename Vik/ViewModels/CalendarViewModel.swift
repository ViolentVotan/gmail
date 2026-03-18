import SwiftUI
import Foundation
internal import GRDB
private import os

@Observable
@MainActor
final class CalendarViewModel {

    // MARK: - State

    var viewMode: CalendarViewMode = .week
    var selectedDate: Date = .now
    var events: [CalendarEvent] = []
    var calendars: [CalendarInfo] = []
    var isLoading = false
    var error: CalendarAPIError?
    var selectedEvent: CalendarEvent?

    /// Set of composite IDs ("\(accountID)\u{001F}\(calendarId)") using Unit Separator for unified multi-account view.
    var visibleCalendarIDs: Set<String> = []

    /// Called after any successful event mutation (create, update, delete, RSVP, quick-add).
    @ObservationIgnored var onEventMutated: (() async -> Void)?

    // MARK: - Dependencies

    let db: MailDatabase
    private let eventService = CalendarEventService.shared
    private let listService = CalendarListService.shared
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "CalendarViewModel")

    // MARK: - Reactive Observation

    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var calendarObservationTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

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
        observeCalendars()
        observeEvents()
    }

    private func observeCalendars() {
        calendarObservationTask?.cancel()
        let dbPool = db.dbPool
        let calendarObservation = ValueObservation.tracking { db in
            try MailDatabaseQueries.allVisibleCalendars(in: db)
        }
        calendarObservationTask = Task { @MainActor [weak self] in
            do {
                for try await records in calendarObservation.values(in: dbPool) {
                    guard let self else { return }
                    self.calendars = records.map { $0.toCalendarInfo() }
                    let newVisibleIDs = Set(records.map { "\($0.accountId)\u{001F}\($0.calendarId)" })
                    let changed = newVisibleIDs != self.visibleCalendarIDs
                    self.visibleCalendarIDs = newVisibleIDs
                    if changed {
                        self.refreshObservation()
                    }
                }
            } catch {
                Self.logger.error("Calendar observation failed: \(error.localizedDescription)")
            }
        }
    }

    private func observeEvents() {
        observationTask?.cancel()
        let dateRange = currentDateRange
        let visibleIDs = visibleCalendarIDs
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
            return
        }
        let start = dateRange.start.timeIntervalSince1970
        let end = dateRange.end.timeIntervalSince1970
        let observation = ValueObservation.tracking { db in
            try MailDatabaseQueries.eventsForDateRange(
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
                        self.events = await self.enrichRecords(records)
                    }
                }
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
        case .week:
            selectedDate = calendar.date(byAdding: .weekOfYear, value: 1, to: selectedDate) ?? selectedDate
        case .day:
            selectedDate = calendar.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
        case .agenda:
            selectedDate = calendar.date(byAdding: .weekOfYear, value: 1, to: selectedDate) ?? selectedDate
        }
        refreshObservation()
    }

    func navigateBackward() {
        let calendar = Calendar.current
        switch viewMode {
        case .week:
            selectedDate = calendar.date(byAdding: .weekOfYear, value: -1, to: selectedDate) ?? selectedDate
        case .day:
            selectedDate = calendar.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
        case .agenda:
            selectedDate = calendar.date(byAdding: .weekOfYear, value: -1, to: selectedDate) ?? selectedDate
        }
        refreshObservation()
    }

    func goToToday() {
        selectedDate = .now
        refreshObservation()
    }

    func selectDate(_ date: Date) {
        selectedDate = date
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
            CalendarOfflineActionQueue.shared.enqueue(.init(
                id: UUID(),
                accountID: accountID,
                createdAt: .now,
                actionType: .createEvent(calendarId: calendarId, input: input)
            ))
        } catch {
            self.error = error
            throw error
        }
        await onEventMutated?()
    }

    func updateEvent(_ event: CalendarEvent, input: CalendarAPIEventInput) async throws {
        error = nil
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await eventService.updateEvent(
                calendarId: event.calendarId,
                eventId: event.googleEventId,
                event: input,
                accountID: event.accountID,
                etag: event.etag
            )
        } catch CalendarAPIError.offline {
            CalendarOfflineActionQueue.shared.enqueue(.init(
                id: UUID(),
                accountID: event.accountID,
                createdAt: .now,
                actionType: .updateEvent(
                    calendarId: event.calendarId,
                    eventId: event.googleEventId,
                    input: input,
                    etag: event.etag
                )
            ))
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
        // Snapshot for rollback before optimistic delete.
        let snapshot: (CalendarEventRecord, [CalendarAttendeeRecord])? = try? await db.dbPool.read { db in
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
            return (eventRecord, attendees)
        }
        // Optimistic local removal regardless of connectivity.
        try? await db.dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM calendar_events WHERE event_id = ? AND calendar_id = ? AND account_id = ?",
                arguments: [event.googleEventId, event.calendarId, event.accountID]
            )
            try db.execute(
                sql: "DELETE FROM calendar_attendees WHERE event_id = ? AND calendar_id = ? AND account_id = ?",
                arguments: [event.googleEventId, event.calendarId, event.accountID]
            )
        }
        do {
            try await eventService.deleteEvent(
                calendarId: event.calendarId,
                eventId: event.googleEventId,
                accountID: event.accountID
            )
        } catch CalendarAPIError.offline {
            CalendarOfflineActionQueue.shared.enqueue(.init(
                id: UUID(),
                accountID: event.accountID,
                createdAt: .now,
                actionType: .deleteEvent(calendarId: event.calendarId, eventId: event.googleEventId)
            ))
        } catch {
            // Rollback: re-insert the deleted records.
            if let (eventRecord, attendees) = snapshot {
                try? await db.dbPool.write { db in
                    try eventRecord.insert(db)
                    for attendee in attendees { try attendee.insert(db) }
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
        try? await db.dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE calendar_events SET self_response_status = ?
                    WHERE event_id = ? AND calendar_id = ? AND account_id = ?
                    """,
                arguments: [status.rawValue, event.googleEventId, event.calendarId, event.accountID]
            )
        }
        do {
            _ = try await eventService.respondToEvent(
                calendarId: event.calendarId,
                eventId: event.googleEventId,
                accountID: event.accountID,
                status: status.rawValue
            )
        } catch CalendarAPIError.offline {
            CalendarOfflineActionQueue.shared.enqueue(.init(
                id: UUID(),
                accountID: event.accountID,
                createdAt: .now,
                actionType: .rsvpEvent(calendarId: event.calendarId, eventId: event.googleEventId, status: status.rawValue)
            ))
        } catch {
            // Rollback: restore previous RSVP status.
            try? await db.dbPool.write { db in
                try db.execute(
                    sql: """
                        UPDATE calendar_events SET self_response_status = ?
                        WHERE event_id = ? AND calendar_id = ? AND account_id = ?
                        """,
                    arguments: [previousStatus.rawValue, event.googleEventId, event.calendarId, event.accountID]
                )
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

    var selectedWeek: DateInterval {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: selectedDate) else {
            let start = calendar.startOfDay(for: selectedDate)
            return DateInterval(start: start, end: start.addingTimeInterval(7 * 86400))
        }
        return interval
    }

    func eventsForDay(_ date: Date) -> [CalendarEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return events.filter { $0.startTime < end && $0.endTime > start }
    }

    // MARK: - Private

    /// The date range for the current view mode, used to scope the DB query.
    private var currentDateRange: DateInterval {
        let calendar = Calendar.current
        switch viewMode {
        case .week:
            return selectedWeek
        case .day:
            let start = calendar.startOfDay(for: selectedDate)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return DateInterval(start: start, end: end)
        case .agenda:
            // Agenda shows 2 weeks of upcoming events.
            let start = calendar.startOfDay(for: selectedDate)
            let end = calendar.date(byAdding: .day, value: 14, to: start)!
            return DateInterval(start: start, end: end)
        }
    }

    /// Enriches event records with attendee data and resolved colors.
    private func enrichRecords(_ records: [CalendarEventRecord]) async -> [CalendarEvent] {
        guard !records.isEmpty else { return [] }

        // Build a lookup of calendar colors by calendarId.
        let calendarColorMap: [String: Color] = calendars.reduce(into: [:]) { map, cal in
            map[cal.calendarId] = Color(hex: cal.backgroundColor)
        }

        // Batch-fetch all attendees for all event records in a single async DB read.
        let compositeKeys = records.map { ($0.eventId, $0.calendarId, $0.accountId) }
        let allAttendees: [CalendarAttendeeRecord] = (try? await db.dbPool.read { db in
            // Build OR-chained filter: (event_id = ? AND calendar_id = ? AND account_id = ?) OR ...
            guard let first = compositeKeys.first else { return [] }
            var filter = Column("event_id") == first.0
                && Column("calendar_id") == first.1
                && Column("account_id") == first.2
            for key in compositeKeys.dropFirst() {
                filter = filter
                    || (Column("event_id") == key.0
                        && Column("calendar_id") == key.1
                        && Column("account_id") == key.2)
            }
            return try CalendarAttendeeRecord.filter(filter).fetchAll(db)
        }) ?? []

        // Group attendees by composite key for O(1) lookup.
        let attendeesByKey: [String: [CalendarAttendeeRecord]] = Dictionary(
            grouping: allAttendees
        ) { "\($0.eventId)\u{001F}\($0.calendarId)\u{001F}\($0.accountId)" }

        return records.compactMap { record in
            let key = "\(record.eventId)\u{001F}\(record.calendarId)\u{001F}\(record.accountId)"
            let attendees = attendeesByKey[key] ?? []
            let calendarColor = calendarColorMap[record.calendarId] ?? BrandColor.blue
            return record.toCalendarEvent(attendees: attendees, calendarColor: calendarColor)
        }
    }
}
