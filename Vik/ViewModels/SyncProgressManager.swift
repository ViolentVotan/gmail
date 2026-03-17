// Vik/ViewModels/SyncProgressManager.swift
import SwiftUI

enum SyncPhase: Equatable {
    case idle(lastSynced: Date?)
    case initialSync(synced: Int, estimated: Int)
    case bodyPrefetch(remaining: Int)
    case syncing(remaining: Int?)
    case success
    case error(String)
}

@Observable @MainActor
final class SyncProgressManager {
    // MARK: - Public State

    private(set) var phase: SyncPhase = .idle(lastSynced: nil)

    // MARK: - Private

    private var lastSynced: Date?
    private var lingerTask: Task<Void, Never>?
    private let successLinger: Duration = .seconds(1.5)
    private let errorLinger: Duration = .seconds(2.5)

    // MARK: - Public API

    /// Call when a sync operation begins.
    func syncStarted() {
        lingerTask?.cancel()
        lingerTask = nil
        withAnimation(VikAnimation.springSnappy) {
            phase = .syncing(remaining: nil)
        }
    }

    /// Call to update the remaining message count during a large sync.
    func syncProgress(remaining: Int) {
        guard case .syncing = phase else { return }
        withAnimation(VikAnimation.springDefault) {
            phase = .syncing(remaining: remaining >= 50 ? remaining : nil)
        }
    }

    /// Call to report initial sync progress.
    func initialSyncProgress(synced: Int, estimated: Int) {
        lingerTask?.cancel()
        lingerTask = nil
        withAnimation(VikAnimation.springDefault) {
            phase = .initialSync(synced: synced, estimated: estimated)
        }
    }

    /// Call to report body pre-fetch progress.
    func bodyPrefetchProgress(remaining: Int) {
        guard remaining > 0 else {
            syncCompleted()
            return
        }
        lingerTask?.cancel()
        lingerTask = nil
        withAnimation(VikAnimation.springDefault) {
            phase = .bodyPrefetch(remaining: remaining)
        }
    }

    /// Call when sync completes successfully.
    func syncCompleted() {
        lastSynced = Date()
        withAnimation(VikAnimation.springDefault) {
            phase = .success
        }
        scheduleDismiss(after: successLinger)
    }

    /// Call when sync fails with a transient error.
    func syncFailed(_ message: String = "Sync failed") {
        withAnimation(VikAnimation.springDefault) {
            phase = .error(message)
        }
        scheduleDismiss(after: errorLinger)
    }

    /// Cancel all timers and return to idle. Call on account switch.
    func reset() {
        lingerTask?.cancel()
        lingerTask = nil
        lastSynced = nil
        phase = .idle(lastSynced: nil)
    }

    /// Update the last-synced timestamp (called by loadCurrentFolder for DB-reload paths).
    func updateLastSynced(_ date: Date = Date()) {
        lastSynced = date
        if case .idle = phase {
            phase = .idle(lastSynced: lastSynced)
        }
    }

    // MARK: - Private

    private func scheduleDismiss(after delay: Duration) {
        lingerTask?.cancel()
        lingerTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(VikAnimation.springGentle) {
                phase = .idle(lastSynced: lastSynced)
            }
        }
    }
}
