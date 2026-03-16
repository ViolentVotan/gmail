import Foundation
private import os

@Observable
@MainActor
final class SnoozeMonitor {
    static let shared = SnoozeMonitor()
    private init() {}

    nonisolated private static let logger = Logger(subsystem: "com.vikingz.serif", category: "SnoozeMonitor")

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

    private func checkExpired() async {
        guard !isCheckingExpired else { return }
        isCheckingExpired = true
        defer { isCheckingExpired = false }
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
                    Self.logger.info("Snoozed message \(item.messageId, privacy: .private) deleted (404) — removing snooze entry")
                    snoozeFailureCounts.removeValue(forKey: item.messageId)
                    SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
                } else {
                    Self.logger.error("Error unsnoozing \(item.messageId, privacy: .private): \(error.localizedDescription, privacy: .public)")
                    let count = (snoozeFailureCounts[item.messageId] ?? 0) + 1
                    snoozeFailureCounts[item.messageId] = count
                    if count >= failureNotifyThreshold {
                        ToastManager.shared.show(message: "Failed to unsnooze email", type: .error)
                        snoozeFailureCounts.removeValue(forKey: item.messageId)
                        SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
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
                    Self.logger.info("Scheduled draft \(item.draftId, privacy: .private) deleted (404) — removing schedule entry")
                    scheduledSendFailureCounts.removeValue(forKey: item.draftId)
                    ScheduledSendStore.shared.remove(draftId: item.draftId, accountID: item.accountID)
                } else {
                    Self.logger.error("Error sending scheduled draft \(item.draftId, privacy: .private): \(error.localizedDescription, privacy: .public)")
                    let count = (scheduledSendFailureCounts[item.draftId] ?? 0) + 1
                    scheduledSendFailureCounts[item.draftId] = count
                    if count >= failureNotifyThreshold {
                        ToastManager.shared.show(message: "Failed to send scheduled email", type: .error)
                        scheduledSendFailureCounts.removeValue(forKey: item.draftId)
                        ScheduledSendStore.shared.remove(draftId: item.draftId, accountID: item.accountID)
                    }
                }
            }
        }
    }
}
