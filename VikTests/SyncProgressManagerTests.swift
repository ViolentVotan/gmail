import Testing
import Foundation
@testable import Vik

@MainActor
@Suite("SyncProgressManager")
struct SyncProgressManagerTests {

    @Test("starts in idle with nil timestamp")
    func initialState() {
        let manager = SyncProgressManager()
        #expect(manager.phase == .idle(lastSynced: nil))
    }

    @Test("syncStarted transitions to syncing")
    func syncStarted() {
        let manager = SyncProgressManager()
        manager.syncStarted()
        #expect(manager.phase == .syncing(remaining: nil))
    }

    @Test("syncProgress shows remaining count at threshold")
    func syncProgressLarge() {
        let manager = SyncProgressManager()
        manager.syncStarted()
        manager.syncProgress(remaining: 50)
        #expect(manager.phase == .syncing(remaining: 50))
    }

    @Test("syncProgress suppresses count below 50")
    func syncProgressSmall() {
        let manager = SyncProgressManager()
        manager.syncStarted()
        manager.syncProgress(remaining: 10)
        #expect(manager.phase == .syncing(remaining: nil))
    }

    @Test("syncCompleted transitions to success then idle with timestamp")
    func syncCompleted() async throws {
        let manager = SyncProgressManager()
        manager.syncStarted()
        manager.syncCompleted()
        #expect(manager.phase == .success)
        try await Task.sleep(for: .seconds(2))
        if case .idle(let date) = manager.phase {
            #expect(date != nil)
        } else {
            Issue.record("Expected idle phase after linger")
        }
    }

    @Test("syncFailed transitions to error then idle preserving previous timestamp")
    func syncFailed() async throws {
        let manager = SyncProgressManager()
        manager.syncStarted()
        manager.syncCompleted()
        try await Task.sleep(for: .seconds(2))
        guard case .idle(let previousDate) = manager.phase else {
            Issue.record("Expected idle after first sync")
            return
        }
        manager.syncStarted()
        manager.syncFailed("Token expired")
        #expect(manager.phase == .error("Token expired"))
        try await Task.sleep(for: .seconds(3))
        if case .idle(let date) = manager.phase {
            #expect(date == previousDate)
        } else {
            Issue.record("Expected idle phase after error linger")
        }
    }

    @Test("reset clears to idle with nil timestamp")
    func reset() {
        let manager = SyncProgressManager()
        manager.syncStarted()
        manager.reset()
        #expect(manager.phase == .idle(lastSynced: nil))
    }

    @Test("initialSyncProgress sets phase directly")
    func initialSyncProgress() {
        let manager = SyncProgressManager()
        manager.initialSyncProgress(synced: 100, estimated: 500)
        #expect(manager.phase == .initialSync(synced: 100, estimated: 500))
    }

    @Test("bodyPrefetchProgress with zero completes sync")
    func bodyPrefetchZero() {
        let manager = SyncProgressManager()
        manager.syncStarted()
        manager.bodyPrefetchProgress(remaining: 0)
        #expect(manager.phase == .success)
    }

    @Test("updateLastSynced updates idle phase timestamp")
    func updateLastSynced() {
        let manager = SyncProgressManager()
        let date = Date()
        manager.updateLastSynced(date)
        #expect(manager.phase == .idle(lastSynced: date))
    }

    @Test("updateLastSynced during syncing stores timestamp but does not change phase")
    func updateLastSyncedDuringSyncing() {
        let manager = SyncProgressManager()
        manager.syncStarted()
        manager.updateLastSynced()
        #expect(manager.phase == .syncing(remaining: nil))
    }
}
