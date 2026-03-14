import Testing
import GRDB
@testable import Serif

@Suite struct FullSyncEngineTests {
    @Test func engineStartsInIdleState() async throws {
        let engine = try await makeMockEngine()
        let state = await engine.state
        #expect(state == .idle)
    }

    @Test func engineTransitionsToInitialSync() async throws {
        let engine = try await makeMockEngine()
        await engine.start()
        // Allow a brief moment for the state transition
        try await Task.sleep(for: .milliseconds(100))
        let state = await engine.state
        #expect(state == .initialSync || state == .monitoring)
        await engine.stop()
    }

    @Test func stopResetsToIdle() async throws {
        let engine = try await makeMockEngine()
        await engine.start()
        try await Task.sleep(for: .milliseconds(50))
        await engine.stop()
        let state = await engine.state
        #expect(state == .idle)
    }

    @Test func triggerIncrementalSyncRequiresMonitoring() async throws {
        let engine = try await makeMockEngine()
        // Engine is idle — triggerIncrementalSync should be a no-op
        await engine.triggerIncrementalSync()
        let state = await engine.state
        #expect(state == .idle)
    }

    private func makeMockEngine() async throws -> FullSyncEngine {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("serif-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let mailDB = try MailDatabase(accountID: "test", baseDirectory: tmpDir)
        let syncer = BackgroundSyncer(db: mailDB)
        return FullSyncEngine(
            accountID: "test@example.com",
            db: mailDB,
            syncer: syncer,
            api: MockMessageFetching()
        )
    }
}
