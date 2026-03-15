import Foundation
private import os

/// Legacy on-disk format (version 1). Kept only for migration.
private struct LegacyOfflineQueueFileContents: Codable, Sendable {
    var version: Int = 1
    var actions: [OfflineAction] = []
}

@Observable
@MainActor
final class OfflineActionQueue {
    static let shared = OfflineActionQueue()
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.serif", category: "OfflineQueue")

    private let store = PerAccountFileStore<OfflineAction>(
        fileURL: { accountID in
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.vikingz.serif.app/offline-queue/\(accountID).json")
        },
        legacyDecoder: { data in
            guard let contents = try? JSONDecoder().decode(LegacyOfflineQueueFileContents.self, from: data) else {
                return nil
            }
            return contents.actions
        }
    )

    private init() {}

    private(set) var isDraining = false
    private var retryDelay: TimeInterval = 2.0
    private var retryTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?

    /// Flat view of all pending actions across all accounts.
    var pendingActions: [OfflineAction] {
        store.allItems
    }

    var pendingCount: Int { pendingActions.count }

    func enqueue(_ action: OfflineAction) {
        store.append(action, accountID: action.accountID)
        store.save(accountID: action.accountID)
    }

    /// Removes all pending actions for the given account and deletes its on-disk JSON file.
    func deleteAccount(_ accountID: String) {
        store.deleteAccount(accountID)
    }

    func load(accountID: String) {
        store.loadMerging(accountID: accountID)
    }

    func startDraining() {
        // Cancel any pending retry and stale drain — a fresh drain supersedes them.
        retryTask?.cancel()
        retryTask = nil
        drainTask?.cancel()
        drainTask = nil
        isDraining = false  // Reset before guard to prevent stuck state when cancelled during backoff
        guard !pendingActions.isEmpty else { return }
        isDraining = true

        drainTask = Task {
            var succeeded = 0
            var hitError = false
            while let action = pendingActions.first {
                do {
                    try await executeAction(action)
                    removeAction(action)
                    succeeded += 1
                } catch {
                    if case .httpError(404, _) = error as? GmailAPIError {
                        removeAction(action)
                    } else {
                        Self.logger.warning("Drain error: \(error.localizedDescription, privacy: .public), retrying in \(self.retryDelay)s")
                        hitError = true
                        break
                    }
                }
            }
            if succeeded > 0 {
                retryDelay = 2.0
                ToastManager.shared.show(message: "Synced \(succeeded) action\(succeeded == 1 ? "" : "s")")
            }
            if hitError {
                // Keep isDraining = true through the retry delay to block concurrent
                // startDraining() calls. No flicker — we never set false then true.
                let delay = retryDelay
                retryDelay = min(retryDelay * 2, 60)
                retryTask = Task {
                    try? await Task.sleep(for: .seconds(delay))
                    isDraining = false
                    guard !Task.isCancelled else { return }
                    startDraining()
                }
            } else {
                isDraining = false
            }
        }
    }

    // MARK: - Execution

    private func executeAction(_ action: OfflineAction) async throws {
        switch action.actionType {
        case .trash:
            // Trash uses a per-message API endpoint — must loop sequentially.
            try await executeSequentially(action)
        case .archive:
            try await GmailMessageService.shared.batchModifyLabels(
                ids: action.messageIds,
                add: [],
                remove: [GmailSystemLabel.inbox],
                accountID: action.accountID
            )
        case .markRead:
            try await GmailMessageService.shared.batchModifyLabels(
                ids: action.messageIds,
                add: [],
                remove: [GmailSystemLabel.unread],
                accountID: action.accountID
            )
        case .markUnread:
            try await GmailMessageService.shared.batchModifyLabels(
                ids: action.messageIds,
                add: [GmailSystemLabel.unread],
                remove: [],
                accountID: action.accountID
            )
        case .star:
            try await GmailMessageService.shared.batchModifyLabels(
                ids: action.messageIds,
                add: [GmailSystemLabel.starred],
                remove: [],
                accountID: action.accountID
            )
        case .unstar:
            try await GmailMessageService.shared.batchModifyLabels(
                ids: action.messageIds,
                add: [],
                remove: [GmailSystemLabel.starred],
                accountID: action.accountID
            )
        case .addLabel:
            guard let labelId = action.metadata["labelId"] else {
                Self.logger.warning("addLabel action missing labelId — skipping")
                return
            }
            try await GmailMessageService.shared.batchModifyLabels(
                ids: action.messageIds,
                add: [labelId],
                remove: [],
                accountID: action.accountID
            )
        case .removeLabel:
            guard let labelId = action.metadata["labelId"] else {
                Self.logger.warning("removeLabel action missing labelId — skipping")
                return
            }
            try await GmailMessageService.shared.batchModifyLabels(
                ids: action.messageIds,
                add: [],
                remove: [labelId],
                accountID: action.accountID
            )
        case .spam:
            try await GmailMessageService.shared.batchModifyLabels(
                ids: action.messageIds,
                add: [GmailSystemLabel.spam],
                remove: [GmailSystemLabel.inbox],
                accountID: action.accountID
            )
        }
    }

    /// Sequential per-message execution for actions that don't support batchModify
    /// (e.g. trash). Prunes completed message IDs so retries skip finished work.
    private func executeSequentially(_ action: OfflineAction) async throws {
        var remainingIds = action.messageIds
        for msgId in action.messageIds {
            try await GmailMessageService.shared.trashMessage(id: msgId, accountID: action.accountID)
            remainingIds.removeAll { $0 == msgId }
            persistRemainingIds(remainingIds, for: action)
        }
    }

    // MARK: - Internal Helpers

    /// Removes a completed action from the store and persists.
    private func removeAction(_ action: OfflineAction) {
        store.removeAll(accountID: action.accountID) { $0.id == action.id }
        store.save(accountID: action.accountID)
    }

    /// Replaces the in-memory action with an updated copy holding only `remainingIds`,
    /// ensuring retries do not re-execute already-completed messages.
    private func persistRemainingIds(_ remainingIds: [String], for action: OfflineAction) {
        let accountID = action.accountID
        guard var accountItems = store.itemsByAccount[accountID],
              let idx = accountItems.firstIndex(where: { $0.id == action.id }) else { return }
        accountItems[idx] = OfflineAction(
            id: action.id,
            actionType: action.actionType,
            messageIds: remainingIds,
            accountID: action.accountID,
            timestamp: action.timestamp,
            metadata: action.metadata
        )
        store.replaceItems(accountItems, accountID: accountID)
        store.save(accountID: accountID)
    }
}
