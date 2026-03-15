import Foundation

@Observable
@MainActor
final class SnoozeMonitor {
    static let shared = SnoozeMonitor()
    private init() {}

    private var timerTask: Task<Void, Never>?

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
                SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
            } catch {
                if case .httpError(404, _) = error {
                    SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
                }
            }
        }
    }

    private func checkScheduledSends() async {
        let due = ScheduledSendStore.shared.dueItems()
        for item in due {
            do {
                try await GmailDraftService.shared.sendDraft(draftId: item.draftId, accountID: item.accountID)
                ScheduledSendStore.shared.remove(draftId: item.draftId, accountID: item.accountID)
                ToastManager.shared.show(message: "Scheduled email sent: \(item.subject)")
            } catch {
                if case .httpError(404, _) = error {
                    ScheduledSendStore.shared.remove(draftId: item.draftId, accountID: item.accountID)
                }
            }
        }
    }
}
