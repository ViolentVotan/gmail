import Foundation
private import os

@Observable
@MainActor
final class OfflineActionQueue {
    static let shared = OfflineActionQueue()
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.serif", category: "OfflineQueue")
    private init() {}

    private(set) var pendingActions: [OfflineAction] = []
    private(set) var isDraining = false
    private var retryDelay: TimeInterval = 2.0
    private var retryTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?

    var pendingCount: Int { pendingActions.count }

    func enqueue(_ action: OfflineAction) {
        pendingActions.append(action)
        save(accountID: action.accountID)
    }

    /// Removes all pending actions for the given account and deletes its on-disk JSON file.
    func deleteAccount(_ accountID: String) {
        pendingActions.removeAll { $0.accountID == accountID }
        let url = fileURL(for: accountID)
        try? FileManager.default.removeItem(at: url)
    }

    func load(accountID: String) {
        let url = fileURL(for: accountID)
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(OfflineQueueFileContents.self, from: data) else { return }
        let existingIds = Set(pendingActions.filter { $0.accountID == accountID }.map { $0.id })
        let newFromDisk = contents.actions.filter { !existingIds.contains($0.id) }
        pendingActions.append(contentsOf: newFromDisk)
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
                    pendingActions.removeFirst()
                    save(accountID: action.accountID)
                    succeeded += 1
                } catch {
                    if case .httpError(404, _) = error as? GmailAPIError {
                        pendingActions.removeFirst()
                        save(accountID: action.accountID)
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

    private func executeAction(_ action: OfflineAction) async throws {
        // Work through messageIds sequentially. After each success, prune that ID
        // from the persisted action so a retry won't re-execute already-completed work.
        var remainingIds = action.messageIds
        for msgId in action.messageIds {
            switch action.actionType {
            case .archive:
                try await GmailMessageService.shared.archiveMessage(id: msgId, accountID: action.accountID)
            case .trash:
                try await GmailMessageService.shared.trashMessage(id: msgId, accountID: action.accountID)
            case .star:
                try await GmailMessageService.shared.setStarred(true, id: msgId, accountID: action.accountID)
            case .unstar:
                try await GmailMessageService.shared.setStarred(false, id: msgId, accountID: action.accountID)
            case .markRead:
                try await GmailMessageService.shared.markAsRead(id: msgId, accountID: action.accountID)
            case .markUnread:
                try await GmailMessageService.shared.markAsUnread(id: msgId, accountID: action.accountID)
            case .addLabel:
                guard let labelId = action.metadata["labelId"] else {
                    Self.logger.warning("addLabel action missing labelId — skipping message \(msgId, privacy: .public)")
                    remainingIds.removeAll { $0 == msgId }
                    persistRemainingIds(remainingIds, for: action)
                    continue
                }
                try await GmailMessageService.shared.modifyLabels(id: msgId, add: [labelId], remove: [], accountID: action.accountID)
            case .removeLabel:
                guard let labelId = action.metadata["labelId"] else {
                    Self.logger.warning("removeLabel action missing labelId — skipping message \(msgId, privacy: .public)")
                    remainingIds.removeAll { $0 == msgId }
                    persistRemainingIds(remainingIds, for: action)
                    continue
                }
                try await GmailMessageService.shared.modifyLabels(id: msgId, add: [], remove: [labelId], accountID: action.accountID)
            case .spam:
                try await GmailMessageService.shared.spamMessage(id: msgId, accountID: action.accountID)
            }
            // Message succeeded — prune it so a retry skips it.
            remainingIds.removeAll { $0 == msgId }
            persistRemainingIds(remainingIds, for: action)
        }
    }

    /// Replaces the in-memory action with an updated copy holding only `remainingIds`,
    /// ensuring retries do not re-execute already-completed messages.
    private func persistRemainingIds(_ remainingIds: [String], for action: OfflineAction) {
        guard let idx = pendingActions.indices.first(where: { pendingActions[$0].id == action.id }) else { return }
        pendingActions[idx] = OfflineAction(
            id: action.id,
            actionType: action.actionType,
            messageIds: remainingIds,
            accountID: action.accountID,
            timestamp: action.timestamp,
            metadata: action.metadata
        )
    }

    private func save(accountID: String) {
        let url = fileURL(for: accountID)
        let contents = OfflineQueueFileContents(version: 1, actions: pendingActions.filter { $0.accountID == accountID })
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(contents).write(to: url, options: .atomic)
    }

    private func fileURL(for accountID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vikingz.serif.app/offline-queue/\(accountID).json")
    }
}

private struct OfflineQueueFileContents: Codable {
    var version: Int = 1
    var actions: [OfflineAction] = []
}
