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
    private var deferralTask: Task<Void, Never>?
    private var syncPending = false
    private let successLinger: Duration = .seconds(1.5)
    private let errorLinger: Duration = .seconds(2.5)
    /// Typical zero-change incremental sync completes in <200ms (single history.list
    /// API call). 300ms gives enough headroom for slow networks while suppressing the
    /// spinner flash for the common no-change case.
    private let syncShowDelay: Duration

    init(syncShowDelay: Duration = .milliseconds(300)) {
        self.syncShowDelay = syncShowDelay
    }

    // MARK: - Public API

    /// Call when a sync operation begins.
    /// The spinner is deferred by 300ms — if the sync completes before then,
    /// no visual change occurs (avoids flash for quick zero-change syncs).
    func syncStarted() {
        lingerTask?.cancel()
        lingerTask = nil
        deferralTask?.cancel()
        deferralTask = nil
        if syncShowDelay == .zero {
            syncPending = false
            phase = .syncing(remaining: nil)
        } else {
            syncPending = true
            deferralTask = Task {
                try? await Task.sleep(for: syncShowDelay)
                guard !Task.isCancelled, syncPending else { return }
                withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springSnappy) {
                    phase = .syncing(remaining: nil)
                }
                deferralTask = nil
            }
        }
    }

    /// Call to update the remaining message count during a large sync.
    func syncProgress(remaining: Int) {
        // If there's substantial work, show spinner immediately (cancel deferral)
        if remaining >= 50, syncPending, case .idle = phase {
            deferralTask?.cancel()
            deferralTask = nil
            withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springSnappy) {
                phase = .syncing(remaining: remaining)
            }
            return
        }
        guard case .syncing = phase else { return }
        withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springDefault) {
            phase = .syncing(remaining: remaining >= 50 ? remaining : nil)
        }
    }

    /// Call to report initial sync progress.
    func initialSyncProgress(synced: Int, estimated: Int) {
        deferralTask?.cancel()
        deferralTask = nil
        syncPending = false
        lingerTask?.cancel()
        lingerTask = nil
        withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springDefault) {
            phase = .initialSync(synced: synced, estimated: estimated)
        }
    }

    /// Call to report body pre-fetch progress.
    func bodyPrefetchProgress(remaining: Int) {
        guard remaining > 0 else {
            syncCompleted()
            return
        }
        deferralTask?.cancel()
        deferralTask = nil
        syncPending = false
        lingerTask?.cancel()
        lingerTask = nil
        withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springDefault) {
            phase = .bodyPrefetch(remaining: remaining)
        }
    }

    /// Call when sync completes successfully.
    func syncCompleted() {
        let wasDeferred = syncPending && deferralTask != nil
        deferralTask?.cancel()
        deferralTask = nil
        syncPending = false
        lastSynced = Date()
        if wasDeferred, case .idle = phase {
            // Spinner was never shown — skip success linger, just update timestamp
            phase = .idle(lastSynced: lastSynced)
            return
        }
        withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springDefault) {
            phase = .success
        }
        scheduleDismiss(after: successLinger)
    }

    /// Call when sync fails with a transient error.
    func syncFailed(_ message: String = "Sync failed") {
        let wasDeferred = syncPending && deferralTask != nil
        deferralTask?.cancel()
        deferralTask = nil
        syncPending = false
        // Spinner was never shown — suppress the error flash (same logic as syncCompleted)
        if wasDeferred, case .idle = phase {
            return
        }
        withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springDefault) {
            phase = .error(message)
        }
        scheduleDismiss(after: errorLinger)
    }

    /// Cancel all timers and return to idle. Call on account switch.
    func reset() {
        deferralTask?.cancel()
        deferralTask = nil
        syncPending = false
        lingerTask?.cancel()
        lingerTask = nil
        lastSynced = nil
        phase = .idle(lastSynced: nil)
    }

    /// Update the last-synced timestamp (called by loadCurrentFolder for DB-reload paths).
    func updateLastSynced(_ date: Date = Date()) {
        guard lastSynced.map({ date.timeIntervalSince($0) > 0.5 }) ?? true else { return }
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
            withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springGentle) {
                phase = .idle(lastSynced: lastSynced)
            }
        }
    }
}
