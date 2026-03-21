import Foundation
private import os

/// Offline queue for calendar mutations. Persists pending actions per-account
/// and replays them in order when connectivity is restored.
///
/// Mirrors the email `OfflineActionQueue` pattern but scoped to calendar CRUD operations.
@Observable
@MainActor
final class CalendarOfflineActionQueue {
    static let shared = CalendarOfflineActionQueue()
    nonisolated private static let logger = Logger(category: "CalendarOfflineQueue")

    private let store = PerAccountFileStore<CalendarOfflineAction>(
        fileURL: { accountID in
            AppPaths.appSupportDirectory
                .appendingPathComponent("calendar-offline-queue/\(accountID).json")
        }
    )

    private init() {}

    // MARK: - Action Model

    struct CalendarOfflineAction: Codable, Sendable, Identifiable {
        let id: UUID
        let accountID: String
        let createdAt: Date
        let actionType: ActionType

        enum ActionType: Codable, Sendable {
            case createEvent(calendarId: String, input: CalendarAPIEventInput, sendUpdates: String? = "all")
            case updateEvent(calendarId: String, eventId: String, input: CalendarAPIEventInput, etag: String, sendUpdates: String? = "all")
            case deleteEvent(calendarId: String, eventId: String, sendUpdates: String? = "all")
            case rsvpEvent(calendarId: String, eventId: String, status: String, sendUpdates: String? = "all")

            var isUpdate: Bool {
                if case .updateEvent = self { return true }
                return false
            }
        }
    }

    // MARK: - State

    /// Set of account IDs currently being processed to prevent concurrent `processQueue` calls.
    private var processingAccounts: Set<String> = []

    var pendingCount: Int {
        store.allItems.count
    }

    // MARK: - Public API

    func enqueue(_ action: CalendarOfflineAction) {
        store.append(action, accountID: action.accountID)
    }

    func pendingActions(for accountID: String) -> [CalendarOfflineAction] {
        return store.itemsByAccount[accountID] ?? []
    }

    /// Processes all pending actions for the given account in order.
    /// Stops on the first failure to preserve ordering guarantees.
    func processQueue(accountID: String) async {
        guard !processingAccounts.contains(accountID) else { return }
        processingAccounts.insert(accountID)
        defer { processingAccounts.remove(accountID) }

        store.loadMerging(accountID: accountID)
        guard let pending = store.itemsByAccount[accountID], !pending.isEmpty else { return }

        var processed: [UUID] = []
        for action in pending {
            do {
                try await execute(action)
                processed.append(action.id)
            } catch CalendarAPIError.conflict(_) where action.actionType.isUpdate {
                // 409 Conflict on update — re-fetch fresh etag and retry once
                let resolved = await resolveConflict(for: action)
                if resolved {
                    processed.append(action.id)
                } else {
                    ToastManager.shared.show(
                        message: "Calendar edit conflicted with a server change",
                        type: .error
                    )
                    break  // leave in queue for retry
                }
            } catch let error where error.isNonRetriable {
                Self.logger.warning("Discarding calendar offline action \(action.id) (non-retriable): \(error)")
                processed.append(action.id)
            } catch {
                Self.logger.error("Failed to process calendar offline action \(action.id): \(error)")
                break
            }
        }

        guard !processed.isEmpty else { return }
        let processedSet = Set(processed)
        store.removeAll(accountID: accountID) { processedSet.contains($0.id) }
    }

    /// Removes all queued actions for the given account and deletes its on-disk file.
    func deleteAccount(_ accountID: String) {
        store.deleteAccount(accountID)
    }

    // MARK: - Execution

    private func execute(_ action: CalendarOfflineAction) async throws(CalendarAPIError) {
        let service = CalendarEventService.shared
        switch action.actionType {
        case .createEvent(let calendarId, let input, let sendUpdates):
            _ = try await service.insertEvent(
                calendarId: calendarId,
                event: input,
                accountID: action.accountID,
                sendUpdates: sendUpdates
            )
        case .updateEvent(let calendarId, let eventId, let input, let etag, let sendUpdates):
            _ = try await service.updateEvent(
                calendarId: calendarId,
                eventId: eventId,
                event: input,
                accountID: action.accountID,
                etag: etag,
                sendUpdates: sendUpdates
            )
        case .deleteEvent(let calendarId, let eventId, let sendUpdates):
            try await service.deleteEvent(
                calendarId: calendarId,
                eventId: eventId,
                accountID: action.accountID,
                sendUpdates: sendUpdates
            )
        case .rsvpEvent(let calendarId, let eventId, let status, let sendUpdates):
            _ = try await service.respondToEvent(
                calendarId: calendarId,
                eventId: eventId,
                accountID: action.accountID,
                status: status,
                sendUpdates: sendUpdates
            )
        }
    }

    /// Re-fetches the event for a fresh etag, then retries the update once.
    /// Returns `true` if the retry succeeded, `false` if it failed (action stays in queue for retry).
    private func resolveConflict(for action: CalendarOfflineAction) async -> Bool {
        guard case .updateEvent(let calendarId, let eventId, let input, _, let sendUpdates) = action.actionType else {
            return false
        }
        let service = CalendarEventService.shared
        do {
            let freshEvent = try await service.getEvent(
                calendarId: calendarId,
                eventId: eventId,
                accountID: action.accountID
            )
            guard let freshEtag = freshEvent.etag else {
                Self.logger.warning("Conflict resolution failed for \(action.id): no etag on re-fetched event")
                return false
            }
            _ = try await service.updateEvent(
                calendarId: calendarId,
                eventId: eventId,
                event: input,
                accountID: action.accountID,
                etag: freshEtag,
                sendUpdates: sendUpdates
            )
            Self.logger.info("Conflict resolved for \(action.id) with fresh etag")
            return true
        } catch {
            Self.logger.warning("Conflict resolution failed for \(action.id): \(error)")
            return false
        }
    }
}
