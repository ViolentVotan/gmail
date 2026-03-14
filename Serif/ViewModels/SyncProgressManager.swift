// Serif/ViewModels/SyncProgressManager.swift
import SwiftUI

enum SyncPhase: Equatable {
    case idle
    case initialSync(synced: Int, estimated: Int)
    case bodyPrefetch(remaining: Int)
    case syncing(remaining: Int?)   // incremental sync — nil = quick, non-nil = large (≥50)
    case success
    case error(String)
}

@Observable @MainActor
final class SyncProgressManager {
    // MARK: - Public State

    private(set) var phase: SyncPhase = .idle

    var isVisible: Bool {
        phase != .idle && !debounceActive
    }

    // MARK: - Private Timers

    private var debounceActive = true
    private var debounceTask: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?

    // MARK: - Constants

    private let debounceDelay: Duration = .milliseconds(150)
    private let successLinger: Duration = .seconds(1.5)
    private let errorLinger: Duration = .seconds(2.5)

    // MARK: - Public API

    /// Call when a sync operation begins.
    func syncStarted() {
        lingerTask?.cancel()
        lingerTask = nil

        phase = .syncing(remaining: nil)
        debounceActive = true

        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: debounceDelay)
            guard !Task.isCancelled else { return }
            withAnimation(SerifAnimation.springSnappy) {
                debounceActive = false
            }
        }
    }

    /// Call to update the remaining message count during a large sync.
    func syncProgress(remaining: Int) {
        guard case .syncing = phase else { return }
        withAnimation(SerifAnimation.springDefault) {
            phase = .syncing(remaining: remaining >= 50 ? remaining : nil)
        }
    }

    /// Call to report initial sync progress.
    func initialSyncProgress(synced: Int, estimated: Int) {
        lingerTask?.cancel()
        lingerTask = nil
        debounceActive = false // always show initial sync
        withAnimation(SerifAnimation.springDefault) {
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
        debounceActive = false
        withAnimation(SerifAnimation.springDefault) {
            phase = .bodyPrefetch(remaining: remaining)
        }
    }

    /// Call when sync completes successfully.
    func syncCompleted() {
        debounceTask?.cancel()

        // If debounce never elapsed, skip showing entirely
        guard !debounceActive else {
            phase = .idle
            debounceActive = true
            return
        }

        withAnimation(SerifAnimation.springDefault) {
            phase = .success
        }
        scheduleDismiss(after: successLinger)
    }

    /// Call when sync fails with a transient error.
    func syncFailed(_ message: String = "Sync failed") {
        debounceTask?.cancel()

        // If debounce never elapsed, skip showing entirely
        guard !debounceActive else {
            phase = .idle
            debounceActive = true
            return
        }

        withAnimation(SerifAnimation.springDefault) {
            phase = .error(message)
        }
        scheduleDismiss(after: errorLinger)
    }

    /// Cancel all timers and return to idle. Call on account switch.
    func reset() {
        debounceTask?.cancel()
        lingerTask?.cancel()
        debounceTask = nil
        lingerTask = nil
        phase = .idle
        debounceActive = true
    }

    // MARK: - Private

    private func scheduleDismiss(after delay: Duration) {
        lingerTask?.cancel()
        lingerTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(SerifAnimation.springGentle) {
                phase = .idle
                debounceActive = true
            }
        }
    }
}
