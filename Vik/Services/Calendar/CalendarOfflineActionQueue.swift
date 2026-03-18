import Foundation
private import os

/// Offline queue for calendar mutations. Persists pending actions per-account
/// and replays them in order when connectivity is restored.
///
/// Mirrors the email `OfflineActionQueue` pattern but scoped to calendar CRUD operations.
@MainActor
final class CalendarOfflineActionQueue {
    static let shared = CalendarOfflineActionQueue()
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "CalendarOfflineQueue")
    private init() {}

    // MARK: - Action Model

    struct CalendarOfflineAction: Codable, Sendable, Identifiable {
        let id: UUID
        let accountID: String
        let createdAt: Date
        let actionType: ActionType

        enum ActionType: Codable, Sendable {
            case createEvent(calendarId: String, input: CalendarAPIEventInput)
            case updateEvent(calendarId: String, eventId: String, input: CalendarAPIEventInput, etag: String)
            case deleteEvent(calendarId: String, eventId: String)
            case rsvpEvent(calendarId: String, eventId: String, status: String)
        }
    }

    // MARK: - State

    /// In-memory queues keyed by accountID. Loaded lazily on first access per account.
    private var actions: [String: [CalendarOfflineAction]] = [:]

    var pendingCount: Int {
        actions.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Public API

    func enqueue(_ action: CalendarOfflineAction) {
        actions[action.accountID, default: []].append(action)
        save(for: action.accountID)
    }

    func pendingActions(for accountID: String) -> [CalendarOfflineAction] {
        loadIfNeeded(for: accountID)
        return actions[accountID] ?? []
    }

    func hasPendingActions(for accountID: String) -> Bool {
        loadIfNeeded(for: accountID)
        return !(actions[accountID]?.isEmpty ?? true)
    }

    /// Processes all pending actions for the given account in order.
    /// Stops on the first failure to preserve ordering guarantees.
    func processQueue(accountID: String) async {
        loadIfNeeded(for: accountID)
        guard var pending = actions[accountID], !pending.isEmpty else { return }

        var processed: [UUID] = []
        for action in pending {
            do {
                try await execute(action)
                processed.append(action.id)
            } catch {
                Self.logger.error("Failed to process calendar offline action \(action.id): \(error)")
                break
            }
        }

        guard !processed.isEmpty else { return }
        pending.removeAll { processed.contains($0.id) }
        actions[accountID] = pending
        save(for: accountID)
    }

    /// Removes all queued actions for the given account and deletes its on-disk file.
    func deleteAccount(_ accountID: String) {
        actions.removeValue(forKey: accountID)
        let url = fileURL(for: accountID)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Execution

    private func execute(_ action: CalendarOfflineAction) async throws {
        let service = CalendarEventService.shared
        switch action.actionType {
        case .createEvent(let calendarId, let input):
            _ = try await service.insertEvent(calendarId: calendarId, event: input, accountID: action.accountID)
        case .updateEvent(let calendarId, let eventId, let input, let etag):
            _ = try await service.updateEvent(calendarId: calendarId, eventId: eventId, event: input, accountID: action.accountID, etag: etag)
        case .deleteEvent(let calendarId, let eventId):
            try await service.deleteEvent(calendarId: calendarId, eventId: eventId, accountID: action.accountID)
        case .rsvpEvent(let calendarId, let eventId, let status):
            _ = try await service.respondToEvent(calendarId: calendarId, eventId: eventId, accountID: action.accountID, status: status)
        }
    }

    // MARK: - Persistence

    private func fileURL(for accountID: String) -> URL {
        let dir = AppPaths.appSupportDirectory
            .appendingPathComponent("calendar-offline-queue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(accountID).json")
    }

    private func save(for accountID: String) {
        let url = fileURL(for: accountID)
        let data = try? JSONEncoder().encode(actions[accountID] ?? [])
        try? data?.write(to: url, options: .atomic)
    }

    private func loadIfNeeded(for accountID: String) {
        guard actions[accountID] == nil else { return }
        let url = fileURL(for: accountID)
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([CalendarOfflineAction].self, from: data) else {
            actions[accountID] = []
            return
        }
        actions[accountID] = loaded
    }
}
