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
    nonisolated private static let logger = Logger(category: "OfflineQueue")

    private let store = PerAccountFileStore<OfflineAction>(
        fileURL: { accountID in
            AppPaths.appSupportDirectory
                .appendingPathComponent("offline-queue/\(accountID).json")
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

    var pendingCount: Int { store.totalCount }

    func enqueue(_ action: OfflineAction) async {
        await store.appendAndWait(action, accountID: action.accountID)
    }

    /// Removes all pending actions for the given account and deletes its on-disk JSON file.
    func deleteAccount(_ accountID: String) {
        store.deleteAccount(accountID)
    }

    func load(accountID: String) async {
        await store.loadMerging(accountID: accountID)
    }

    func startDraining() {
        // Cancel any pending retry and stale drain — a fresh drain supersedes them.
        retryTask?.cancel()
        retryTask = nil
        let oldDrain = drainTask
        drainTask?.cancel()
        drainTask = nil
        isDraining = false  // Reset before guard to prevent stuck state when cancelled during backoff
        retryDelay = 2.0    // Fresh drain cycle starts with base delay
        guard !pendingActions.isEmpty else { return }
        isDraining = true

        drainTask = Task {
            // Bail early if cancelled before waiting for old drain.
            guard !Task.isCancelled else {
                isDraining = false
                return
            }
            // Wait for old drain to finish executing before starting new one
            // to prevent double-sends when both tasks process the same action.
            await oldDrain?.value
            guard !Task.isCancelled else {
                isDraining = false
                return
            }
            var succeeded = 0
            var hitError = false
            // Drain each account independently so one account's failure
            // doesn't block other accounts from making progress.
            let accountIDs = Array(store.itemsByAccount.keys)
            for accountID in accountIDs {
                guard !Task.isCancelled else { break }
                while let action = store.itemsByAccount[accountID]?.first {
                    guard !action.messageIds.isEmpty || action.actionType.isSend else { await removeAction(action); continue }
                    do {
                        try await executeAction(action)
                        await removeAction(action)
                        succeeded += 1
                    } catch {
                        if case .httpError(404, _) = error as? GoogleAPIError {
                            await removeAction(action)
                        } else if case .partialFailure = error as? GoogleAPIError {
                            // Partial success: some messages deleted. Remove action to avoid
                            // infinite retry loop (deleted IDs return 404 on next attempt).
                            // Failed deletions will be retried on next full sync.
                            await removeAction(action)
                        } else if let apiError = error as? GoogleAPIError,
                                  case .httpError(let code, _) = apiError,
                                  (400..<500).contains(code), code != 429 {
                            // Permanent client error (bad request, forbidden, not found, gone, etc.)
                            // Don't retry — remove the action to prevent infinite retry loops.
                            Self.logger.error("Permanent error \(code) for action \(String(describing: action.actionType)) — removing")
                            await removeAction(action)
                        } else {
                            Self.logger.warning("Drain error for account \(accountID, privacy: .private): \(error.localizedDescription, privacy: .public), continuing with next account")
                            hitError = true
                            break
                        }
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
                    guard !Task.isCancelled else {
                        isDraining = false
                        return
                    }
                    isDraining = false
                    startDraining()
                }
            } else {
                isDraining = false
            }
        }
    }

    // MARK: - Execution

    private func executeAction(_ action: OfflineAction) async throws(GoogleAPIError) {
        switch action.actionType {
        case .trash:
            // Trash uses a per-message API endpoint — must loop sequentially.
            try await executeSequentially(action) { msgId, accountID throws(GoogleAPIError) in
                try await GmailMessageService.shared.trashMessage(id: msgId, accountID: accountID)
            }
        case .untrash:
            try await executeSequentially(action) { msgId, accountID throws(GoogleAPIError) in
                try await GmailMessageService.shared.untrashMessage(id: msgId, accountID: accountID)
            }
        case .deletePermanently:
            try await GmailMessageService.shared.batchDelete(
                ids: action.messageIds,
                accountID: action.accountID
            )
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
        case .send(let rawBase64URL, let threadID):
            try await GmailSendService.sendRaw(
                base64url: rawBase64URL,
                threadID: threadID,
                accountID: action.accountID
            )
        }
    }

    /// Sequential per-message execution for actions that don't support batchModify
    /// (e.g. trash, untrash, deletePermanently). Prunes completed message IDs so retries skip finished work.
    private func executeSequentially(
        _ action: OfflineAction,
        perform: (String, String) async throws(GoogleAPIError) -> Void
    ) async throws(GoogleAPIError) {
        for (index, msgId) in action.messageIds.enumerated() {
            try await perform(msgId, action.accountID)
            let remainingIds = Array(action.messageIds[(index + 1)...])
            await persistRemainingIds(remainingIds, for: action)
        }
    }

    // MARK: - Internal Helpers

    /// Removes a completed action from the store and persists.
    private func removeAction(_ action: OfflineAction) async {
        await store.removeAllAndWait(accountID: action.accountID) { $0.id == action.id }
    }

    /// Replaces the in-memory action with an updated copy holding only `remainingIds`,
    /// ensuring retries do not re-execute already-completed messages.
    private func persistRemainingIds(_ remainingIds: [String], for action: OfflineAction) async {
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
        await store.saveAndWait(accountID: accountID)
    }
}
