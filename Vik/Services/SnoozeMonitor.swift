import Foundation
private import os

@Observable
@MainActor
final class SnoozeMonitor {
    static let shared = SnoozeMonitor()
    private init() {}

    nonisolated private static let logger = Logger(category: "SnoozeMonitor")

    private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var isCheckingExpired = false
    private var snoozeFailureCounts: [String: Int] = [:]
    private var scheduledSendFailureCounts: [String: Int] = [:]
    private let failureNotifyThreshold = 5

    func start() {
        guard timerTask == nil else { return }
        timerTask = Task {
            await checkExpired()  // immediate first check
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await checkExpired()
            }
        }
    }

    func stop() async {
        let task = timerTask
        timerTask?.cancel()
        timerTask = nil
        await task?.value
    }

    func clearAllFailureCounts() {
        snoozeFailureCounts.removeAll()
        scheduledSendFailureCounts.removeAll()
    }

    private func checkExpired() async {
        guard !isCheckingExpired else { return }
        isCheckingExpired = true
        defer { isCheckingExpired = false }
        await checkSnoozedItems()
        await checkScheduledSends()
    }

    private func checkSnoozedItems() async {
        let activeAccountIDs = Set(AccountStore.shared.accounts.map(\.id))
        let expired = SnoozeStore.shared.expiredItems().filter { activeAccountIDs.contains($0.accountID) }
        await processExpiredItems(
            items: expired,
            itemID: \.messageId,
            accountID: \.accountID,
            action: { item throws(GoogleAPIError) in
                try await GmailMessageService.shared.modifyLabels(
                    id: item.messageId,
                    add: item.originalLabelIds.isEmpty ? [GmailSystemLabel.inbox] : item.originalLabelIds,
                    remove: [],
                    accountID: item.accountID
                )
            },
            remove: { item in
                await SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
            },
            getFailureCount: { self.snoozeFailureCounts[$0] ?? 0 },
            setFailureCount: { self.snoozeFailureCounts[$0] = $1 },
            removeFailureCount: { _ = self.snoozeFailureCounts.removeValue(forKey: $0) },
            logPrefix: "Snoozed message",
            failureToast: "Failed to unsnooze email"
        )
    }

    private func checkScheduledSends() async {
        let activeAccountIDs = Set(AccountStore.shared.accounts.map(\.id))
        let due = ScheduledSendStore.shared.dueItems().filter { activeAccountIDs.contains($0.accountID) }
        await processExpiredItems(
            items: due,
            itemID: \.draftId,
            accountID: \.accountID,
            action: { item throws(GoogleAPIError) in
                try await GmailDraftService.shared.sendDraft(draftId: item.draftId, accountID: item.accountID)
            },
            remove: { item in
                await ScheduledSendStore.shared.remove(draftId: item.draftId, accountID: item.accountID)
            },
            onSuccess: { item in
                ToastManager.shared.show(message: "Scheduled email sent: \(item.subject)")
            },
            onPermanentFailure: { item in
                await ScheduledSendStore.shared.markFailed(draftId: item.draftId, accountID: item.accountID)
            },
            getFailureCount: { self.scheduledSendFailureCounts[$0] ?? 0 },
            setFailureCount: { self.scheduledSendFailureCounts[$0] = $1 },
            removeFailureCount: { self.scheduledSendFailureCounts.removeValue(forKey: $0) },
            logPrefix: "Scheduled draft",
            failureToast: "Failed to send scheduled email"
        )
    }

    /// Shared loop for processing expired snooze/scheduled-send items.
    ///
    /// Handles retries with failure counting, 404 cleanup, and toast notifications.
    private func processExpiredItems<T>(
        items: [T],
        itemID: KeyPath<T, String>,
        accountID: KeyPath<T, String>,
        action: (T) async throws(GoogleAPIError) -> Void,
        remove: (T) async -> Void,
        onSuccess: ((T) -> Void)? = nil,
        onPermanentFailure: ((T) async -> Void)? = nil,
        getFailureCount: (String) -> Int,
        setFailureCount: (String, Int) -> Void,
        removeFailureCount: (String) -> Void,
        logPrefix: String,
        failureToast: String
    ) async {
        for item in items {
            let id = item[keyPath: itemID]
            let acctID = item[keyPath: accountID]
            let compoundKey = "\(acctID):\(id)"
            do {
                try await action(item)
                removeFailureCount(compoundKey)
                await remove(item)
                onSuccess?(item)
            } catch {
                if case .httpError(404, _) = error {
                    Self.logger.info("\(logPrefix, privacy: .public) \(id, privacy: .private) deleted (404) — removing entry")
                    removeFailureCount(compoundKey)
                    await remove(item)
                } else {
                    Self.logger.error("Error processing \(logPrefix, privacy: .public) \(id, privacy: .private): \(error.localizedDescription, privacy: .public)")
                    let count = getFailureCount(compoundKey) + 1
                    setFailureCount(compoundKey, count)
                    if count >= failureNotifyThreshold {
                        ToastManager.shared.show(message: failureToast, type: .error)
                        if let onPermanentFailure {
                            removeFailureCount(compoundKey)
                            await onPermanentFailure(item)
                        } else {
                            // Keep the item for future retry rather than silently dropping it.
                            // Reset failure count so the next monitor tick retries.
                            setFailureCount(compoundKey, 0)
                            Self.logger.error("Max retries reached for \(id, privacy: .private) — will retry on next tick")
                        }
                    }
                }
            }
        }
    }
}
