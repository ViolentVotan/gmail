import Foundation
private import os

@Observable
@MainActor
final class CalendarCoordinator {

    nonisolated private static let logger = Logger(category: "CalendarCoordinator")

    // MARK: - State

    var viewMode: AppViewMode = .mail
    private(set) var calendarViewModel: CalendarViewModel?
    private(set) var calendarSyncEngine: CalendarSyncEngine?
    var miniAgendaEvents: [CalendarEvent] = []
    var calendarNewEventTrigger: Bool = false

    // MARK: - Actions

    func switchToCalendar(db: MailDatabase?) {
        viewMode = .calendar
        if calendarViewModel == nil, let db {
            calendarViewModel = CalendarViewModel(db: db)
            calendarViewModel?.onEventMutated = { [weak self] in
                await self?.calendarSyncEngine?.triggerSync()
                await self?.calendarSyncEngine?.temporarilyTightenPolling()
            }
            calendarViewModel?.startObserving()
        }
        Task { await calendarSyncEngine?.updatePollingInterval(calendarActive: true, appFocused: true) }
    }

    func switchToMail() {
        viewMode = .mail
        Task { await calendarSyncEngine?.updatePollingInterval(calendarActive: false, appFocused: true) }
    }

    func loadMiniAgendaEvents(db: MailDatabase?, accountID: String) async {
        guard let db else { return }
        let records: [CalendarEventRecord]
        do {
            records = try await db.dbPool.read { db in
                try MailDatabaseQueries.eventsForToday(accountId: accountID, in: db)
            }
        } catch {
            Self.logger.debug("Failed to load mini-agenda events: \(error)")
            return
        }
        guard !Task.isCancelled else { return }
        miniAgendaEvents = records.map { $0.toCalendarEvent(attendees: [], calendarColor: BrandColor.blue) }
    }

    func navigateToEvent(_ event: CalendarEvent, db: MailDatabase?) {
        switchToCalendar(db: db)
        calendarViewModel?.selectedDate = event.startTime
        calendarViewModel?.selectedEvent = event
    }

    func startCalendarSync(for id: String, db: MailDatabase?) async {
        guard let db else { return }
        await CalendarOfflineActionQueue.shared.processQueue(accountID: id)
        let engine = CalendarSyncEngine(accountID: id, db: db)
        guard !Task.isCancelled else { return }
        calendarSyncEngine = engine
        await engine.start()
    }

    func stopCalendarSync() async {
        await calendarSyncEngine?.stop()
        calendarSyncEngine = nil
        calendarViewModel = nil
    }

    /// Clears calendar state synchronously without awaiting engine stop.
    ///
    /// **Caller contract:** The caller **must** capture `calendarSyncEngine` before
    /// calling this method and `await engine.stop()` afterward. Nilling the engine
    /// without stopping it risks in-flight DB writes hitting a closed database.
    ///
    /// Both call sites in `AppCoordinator` (`handleAccountChange`, `handleAccountsChange`)
    /// follow this pattern: capture → clearState → await stop.
    func clearState() {
        calendarSyncEngine = nil
        calendarViewModel = nil
    }
}
