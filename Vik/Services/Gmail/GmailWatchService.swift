import Foundation
private import os

/// Manages Gmail `users.watch` registration and daily renewal for all accounts.
/// Pure background bookkeeping — no UI state.
/// Note: init uses `GmailMessageService.shared` default, which is @MainActor-isolated —
/// create this instance from @MainActor context (e.g., SyncCoordinator).
actor GmailWatchService {

    nonisolated private static let logger = Logger(category: "GmailWatch")

    // MARK: - State

    private var watchExpirations: [String: Date] = [:]  // accountID → expiration
    private var renewalTask: Task<Void, Never>?
    private let api: GmailMessageService

    // MARK: - Init

    @MainActor
    init(api: GmailMessageService = .shared) {
        self.api = api
    }

    // MARK: - Watch Registration

    /// Registers a watch for the given account. Safe to call repeatedly (idempotent).
    func registerWatch(accountID: String) async {
        do {
            let response = try await api.watch(
                accountID: accountID,
                topicName: PubSubConfig.topicName
            )
            if let ms = Double(response.expiration) {
                watchExpirations[accountID] = Date(timeIntervalSince1970: ms / 1000.0)
            }
            Self.logger.info("Watch registered for \(accountID), expires \(response.expiration)")
        } catch {
            Self.logger.error("Watch registration failed for \(accountID): \(error)")
        }
    }

    /// Stops the watch for the given account.
    func stopWatch(accountID: String) async {
        watchExpirations.removeValue(forKey: accountID)
        do {
            try await api.stopWatch(accountID: accountID)
            Self.logger.info("Watch stopped for \(accountID)")
        } catch {
            Self.logger.warning("Watch stop failed for \(accountID): \(error)")
        }
    }

    // MARK: - Renewal Loop

    /// Starts a daily renewal loop for all given accounts.
    func startRenewalLoop(accountIDs: [String]) {
        renewalTask?.cancel()
        renewalTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(PubSubConfig.watchRenewalInterval))
                guard !Task.isCancelled else { return }
                for accountID in accountIDs {
                    await registerWatch(accountID: accountID)
                }
            }
        }
    }

    /// Stops all watches and cancels the renewal loop. Called on app termination.
    func stopAll() async {
        renewalTask?.cancel()
        renewalTask = nil
        for accountID in watchExpirations.keys {
            await stopWatch(accountID: accountID)
        }
    }
}
