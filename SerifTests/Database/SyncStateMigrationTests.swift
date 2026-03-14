import Testing
import GRDB
@testable import Serif

@Suite struct SyncStateMigrationTests {
    @Test func v2MigrationAddsNewColumns() throws {
        let db = try DatabaseQueue()
        try MailDatabaseMigrations.migrator.migrate(db)

        try db.read { db in
            let state = try AccountSyncStateRecord.fetchOne(db, key: 1)
            #expect(state != nil)
            #expect(state?.lastHistoryId == nil)
            #expect(state?.initialSyncComplete == false)
            #expect(state?.initialSyncPageToken == nil)
            #expect(state?.syncedMessageCount == 0)
            #expect(state?.directorySyncToken == nil)
        }
    }

    @Test func v2MigrationDropsFolderSyncState() throws {
        let db = try DatabaseQueue()
        try MailDatabaseMigrations.migrator.migrate(db)

        try db.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            #expect(!tables.contains("folder_sync_state"))
        }
    }
}
