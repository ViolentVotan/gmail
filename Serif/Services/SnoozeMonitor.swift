import Foundation

@Observable
@MainActor
final class SnoozeMonitor {
    static let shared = SnoozeMonitor()
    private init() {}

    private var timerTask: Task<Void, Never>?
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
        await checkSnoozedItems()
        await checkScheduledSends()
    }

    private func checkSnoozedItems() async {
        let expired = SnoozeStore.shared.expiredItems()
        for item in expired {
            do {
                try await GmailMessageService.shared.modifyLabels(
                    id: item.messageId,
                    add: item.originalLabelIds.isEmpty ? [GmailSystemLabel.inbox] : item.originalLabelIds,
                    remove: [],
                    accountID: item.accountID
                )
                snoozeFailureCounts.removeValue(forKey: item.messageId)
                SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
            } catch {
                if case .httpError(404, _) = error {
                    snoozeFailureCounts.removeValue(forKey: item.messageId)
                    SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
                } else {
                    print("[SnoozeMonitor] Error unsnoozing \(item.messageId): \(error)")
                    let count = (snoozeFailureCounts[item.messageId] ?? 0) + 1
                    snoozeFailureCounts[item.messageId] = count
                    if count >= failureNotifyThreshold {
                        ToastManager.shared.show(message: "Failed to unsnooze email", type: .error)
                        snoozeFailureCounts.removeValue(forKey: item.messageId)
                    }
                }
            }
        }
    }

    private func checkScheduledSends() async {
        let due = ScheduledSendStore.shared.dueItems()
        for item in due {
            do {
                try await GmailDraftService.shared.sendDraft(draftId: item.draftId, accountID: item.accountID)
                scheduledSendFailureCounts.removeValue(forKey: item.draftId)
                ScheduledSendStore.shared.remove(draftId: item.draftId, accountID: item.accountID)
                ToastManager.shared.show(message: "Scheduled email sent: \(item.subject)")
            } catch {
                if case .httpError(404, _) = error {
                    scheduledSendFailureCounts.removeValue(forKey: item.draftId)
                    ScheduledSendStore.shared.remove(draftId: item.draftId, accountID: item.accountID)
                } else {
                    print("[SnoozeMonitor] Error sending scheduled draft \(item.draftId): \(error)")
                    let count = (scheduledSendFailureCounts[item.draftId] ?? 0) + 1
                    scheduledSendFailureCounts[item.draftId] = count
                    if count >= failureNotifyThreshold {
                        ToastManager.shared.show(message: "Failed to send scheduled email", type: .error)
                        scheduledSendFailureCounts.removeValue(forKey: item.draftId)
                    }
                }
            }
        }
    }
}
