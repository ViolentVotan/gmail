import Foundation

@Observable
@MainActor
final class OfflineActionQueue {
    static let shared = OfflineActionQueue()
    private init() {}

    private(set) var pendingActions: [OfflineAction] = []
    private(set) var isDraining = false
    private var retryDelay: TimeInterval = 2.0

    var pendingCount: Int { pendingActions.count }

    func enqueue(_ action: OfflineAction) {
        pendingActions.append(action)
        save(accountID: action.accountID)
    }

    func load(accountID: String) {
        let url = fileURL(for: accountID)
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(OfflineQueueFileContents.self, from: data) else { return }
        pendingActions.removeAll { $0.accountID == accountID }
        pendingActions.append(contentsOf: contents.actions)
    }

    func startDraining() {
        guard !isDraining, !pendingActions.isEmpty else { return }
        isDraining = true

        Task {
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
                        print("[OfflineActionQueue] Drain error: \(error), retrying in \(retryDelay)s")
                        hitError = true
                        break
                    }
                }
            }
            isDraining = false
            if succeeded > 0 {
                retryDelay = 2.0
                ToastManager.shared.show(message: "Synced \(succeeded) action\(succeeded == 1 ? "" : "s")")
            }
            if hitError {
                let delay = retryDelay
                retryDelay = min(retryDelay * 2, 60)
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    startDraining()
                }
            }
        }
    }

    private func executeAction(_ action: OfflineAction) async throws {
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
                if let labelId = action.metadata["labelId"] {
                    try await GmailMessageService.shared.modifyLabels(id: msgId, add: [labelId], remove: [], accountID: action.accountID)
                }
            case .removeLabel:
                if let labelId = action.metadata["labelId"] {
                    try await GmailMessageService.shared.modifyLabels(id: msgId, add: [], remove: [labelId], accountID: action.accountID)
                }
            case .spam:
                try await GmailMessageService.shared.spamMessage(id: msgId, accountID: action.accountID)
            }
        }
    }

    private func save(accountID: String) {
        let url = fileURL(for: accountID)
        let contents = OfflineQueueFileContents(version: 1, actions: pendingActions.filter { $0.accountID == accountID })
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(contents).write(to: url, options: .atomic)
    }

    private func fileURL(for accountID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.genyus.serif.app/offline-queue/\(accountID).json")
    }
}

private struct OfflineQueueFileContents: Codable {
    var version: Int = 1
    var actions: [OfflineAction] = []
}
