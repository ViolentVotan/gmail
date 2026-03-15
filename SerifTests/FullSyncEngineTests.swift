import Testing
import Foundation
import GRDB
@testable import Serif

@Suite struct FullSyncEngineTests {
    @Test func engineStartsInIdleState() async throws {
        let (engine, tmpDir) = try await makeMockEngine()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let state = await engine.state
        #expect(state == .idle)
    }

    @Test func engineTransitionsToInitialSync() async throws {
        let (engine, tmpDir) = try await makeMockEngine()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        await engine.start()
        try await waitForState(engine, oneOf: [.initialSync, .monitoring])
        await engine.stop()
    }

    @Test func stopResetsToIdle() async throws {
        let (engine, tmpDir) = try await makeMockEngine()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        await engine.start()
        try await waitForState(engine, oneOf: [.initialSync, .monitoring])
        await engine.stop()
        try await waitForState(engine, .idle)
    }

    @Test func triggerIncrementalSyncRequiresMonitoring() async throws {
        let (engine, tmpDir) = try await makeMockEngine()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // Engine is idle — triggerIncrementalSync should be a no-op
        await engine.triggerIncrementalSync()
        let state = await engine.state
        #expect(state == .idle)
    }

    // MARK: - Helpers

    private func waitForState(
        _ engine: FullSyncEngine,
        _ expected: FullSyncEngine.State,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await engine.state == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await engine.state == expected)
    }

    private func waitForState(
        _ engine: FullSyncEngine,
        oneOf expected: [FullSyncEngine.State],
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let current = await engine.state
            if expected.contains(current) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let finalState = await engine.state
        #expect(expected.contains(finalState),
                "Expected one of \(expected) but got \(finalState)")
    }

    @MainActor
    private func makeMockEngine() async throws -> (FullSyncEngine, URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("serif-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let mailDB = try MailDatabase(accountID: "test", baseDirectory: tmpDir)
        let syncer = BackgroundSyncer(db: mailDB)
        let engine = FullSyncEngine(
            accountID: "test@example.com",
            db: mailDB,
            syncer: syncer,
            api: MockMessageFetching()
        )
        return (engine, tmpDir)
    }
}
