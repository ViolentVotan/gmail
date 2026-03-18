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

    /// Set of composite IDs ("\(accountID)_\(calendarId)") for unified multi-account view.
    var visibleCalendarIDs: Set<String> = []

    // MARK: - Dependencies

    let db: MailDatabase
    private let eventService = CalendarEventService.shared
    private let listService = CalendarListService.shared
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "CalendarViewModel")

    // MARK: - Reactive Observation

    private var observationTask: Task<Void, Never>?
    private var calendarObservationTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

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
                    self.visibleCalendarIDs = Set(records.map { "\($0.accountId)_\($0.calendarId)" })
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
        let calendarIds = visibleIDs.compactMap { id -> String? in
            let parts = id.split(separator: "_", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return String(parts[1])
        }
        guard !calendarIds.isEmpty else {
            events = []
            return
        }
        let start = dateRange.start.timeIntervalSince1970
        let end = dateRange.end.timeIntervalSince1970
        let observation = ValueObservation.tracking { db in
            try MailDatabaseQueries.eventsForDateRange(
                accountId: nil,
                calendarIds: calendarIds,
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
                        self.events = self.enrichRecords(records)
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
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await eventService.insertEvent(
                calendarId: calendarId,
                event: input,
                accountID: accountID
            )
            // Sync engine will pick up the new event via incremental sync.
        } catch {
            self.error = error
            throw error
        }
    }

    func updateEvent(_ event: CalendarEvent, input: CalendarAPIEventInput) async throws {
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
        } catch {
            self.error = error
            throw error
        }
    }

    func deleteEvent(_ event: CalendarEvent) async throws {
        isLoading = true
        defer { isLoading = false }
        do {
            try await eventService.deleteEvent(
                calendarId: event.calendarId,
                eventId: event.googleEventId,
                accountID: event.accountID
            )
            // Optimistic removal from local DB.
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
        } catch {
            self.error = error
            throw error
        }
    }

    func respondToEvent(_ event: CalendarEvent, status: CalendarRSVPStatus) async throws {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await eventService.respondToEvent(
                calendarId: event.calendarId,
                eventId: event.googleEventId,
                accountID: event.accountID,
                status: status.rawValue
            )
            // Optimistic local update of self response status.
            try? await db.dbPool.write { db in
                try db.execute(
                    sql: """
                        UPDATE calendar_events SET self_response_status = ?
                        WHERE event_id = ? AND calendar_id = ? AND account_id = ?
                        """,
                    arguments: [status.rawValue, event.googleEventId, event.calendarId, event.accountID]
                )
            }
        } catch {
            self.error = error
            throw error
        }
    }

    func quickAddEvent(text: String, calendarId: String, accountID: String) async throws {
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
    }

    // MARK: - Helpers

    var selectedWeek: DateInterval {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: selectedDate)
        let startOfWeek = calendar.date(byAdding: .day, value: -(weekday - 1), to: calendar.startOfDay(for: selectedDate))!
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfWeek)!
        return DateInterval(start: startOfWeek, end: endOfWeek)
    }

    func eventsForDay(_ date: Date) -> [CalendarEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return events.filter { $0.startTime < end && $0.endTime > start }
    }

    func eventsForTimeSlot(_ date: Date, hour: Int) -> [CalendarEvent] {
        let calendar = Calendar.current
        guard let slotStart = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date),
              let slotEnd = calendar.date(bySettingHour: hour + 1, minute: 0, second: 0, of: date) else { return [] }
        return events.filter { $0.startTime < slotEnd && $0.endTime > slotStart }
    }

    func hasConflict(start: Date, end: Date) -> Bool {
        events.contains { $0.startTime < end && $0.endTime > start && $0.status != .cancelled }
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
    private func enrichRecords(_ records: [CalendarEventRecord]) -> [CalendarEvent] {
        // Build a lookup of calendar colors by calendarId.
        let calendarColorMap: [String: Color] = calendars.reduce(into: [:]) { map, cal in
            map[cal.calendarId] = Color(hex: cal.backgroundColor)
        }

        return records.compactMap { record in
            let attendees: [CalendarAttendeeRecord] = (try? db.dbPool.read { db in
                try CalendarAttendeeRecord
                    .filter(Column("event_id") == record.eventId)
                    .filter(Column("calendar_id") == record.calendarId)
                    .filter(Column("account_id") == record.accountId)
                    .fetchAll(db)
            }) ?? []

            let calendarColor = calendarColorMap[record.calendarId] ?? BrandColor.blue
            return record.toCalendarEvent(attendees: attendees, calendarColor: calendarColor)
        }
    }
}
