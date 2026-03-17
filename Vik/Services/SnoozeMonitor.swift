import Foundation
private import os

@Observable
@MainActor
final class SnoozeMonitor {
    static let shared = SnoozeMonitor()
    private init() {}

    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "SnoozeMonitor")

    private var timerTask: Task<Void, Never>?
    private var isCheckingExpired = false
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

    func stop() {
        timerTask?.cancel()
        timerTask = nil
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
            action: { item throws(GmailAPIError) in
                try await GmailMessageService.shared.modifyLabels(
                    id: item.messageId,
                    add: item.originalLabelIds.isEmpty ? [GmailSystemLabel.inbox] : item.originalLabelIds,
                    remove: [],
                    accountID: item.accountID
                )
            },
            remove: { item in
                SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
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
            action: { item throws(GmailAPIError) in
                try await GmailDraftService.shared.sendDraft(draftId: item.draftId, accountID: item.accountID)
            },
            remove: { item in
                ScheduledSendStore.shared.remove(draftId: item.draftId, accountID: item.accountID)
            },
            onSuccess: { item in
                ToastManager.shared.show(message: "Scheduled email sent: \(item.subject)")
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
        action: (T) async throws(GmailAPIError) -> Void,
        remove: (T) -> Void,
        onSuccess: ((T) -> Void)? = nil,
        getFailureCount: (String) -> Int,
        setFailureCount: (String, Int) -> Void,
        removeFailureCount: (String) -> Void,
        logPrefix: String,
        failureToast: String
    ) async {
        for item in items {
            let id = item[keyPath: itemID]
            do {
                try await action(item)
                removeFailureCount(id)
                remove(item)
                onSuccess?(item)
            } catch {
                if case .httpError(404, _) = error {
                    Self.logger.info("\(logPrefix, privacy: .public) \(id, privacy: .private) deleted (404) — removing entry")
                    removeFailureCount(id)
                    remove(item)
                } else {
                    Self.logger.error("Error processing \(logPrefix, privacy: .public) \(id, privacy: .private): \(error.localizedDescription, privacy: .public)")
                    let count = getFailureCount(id) + 1
                    setFailureCount(id, count)
                    if count >= failureNotifyThreshold {
                        ToastManager.shared.show(message: failureToast, type: .error)
                        removeFailureCount(id)
                        remove(item)
                    }
                }
            }
        }
    }
}
