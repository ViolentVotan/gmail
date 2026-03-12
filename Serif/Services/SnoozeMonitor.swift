import Foundation

@Observable
@MainActor
final class SnoozeMonitor {
    static let shared = SnoozeMonitor()
    private init() {}

    private var timerTask: Task<Void, Never>?

    func start() {
        guard timerTask == nil else { return }
        Task { await checkExpired() }

        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
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
                if case .httpError(404, _) = error as? GmailAPIError {
                    SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
                }
            }
        }
    }
}
