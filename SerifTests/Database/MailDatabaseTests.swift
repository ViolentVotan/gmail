import Testing
import GRDB
@testable import Serif

@Suite("MailDatabase")
struct MailDatabaseTests {
    @Test("creates database file at expected path")
    func createsDatabaseFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try MailDatabase(accountID: "test-account", baseDirectory: tempDir)
        let dbPath = tempDir.appendingPathComponent("test-account.sqlite").path
        #expect(FileManager.default.fileExists(atPath: dbPath))
        _ = db
    }

    @Test("sets WAL journal mode")
    func setsWALMode() throws {
        let db = try makeTestDatabase()
        let mode = try db.dbPool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(mode == "wal")
    }

    @Test("enables foreign keys")
    func enablesForeignKeys() throws {
        let db = try makeTestDatabase()
        let fk = try db.dbPool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        #expect(fk == 1)
    }

    @Test("integrity check passes on fresh database")
    func integrityCheckPasses() throws {
        let db = try makeTestDatabase()
        #expect(try db.integrityCheck())
    }

    @Test("v1 migration creates all tables")
    func v1CreatesAllTables() throws {
        let db = try makeTestDatabase()
        let tables = try db.dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
            """)
        }
        #expect(tables.contains("messages"))
        #expect(tables.contains("labels"))
        #expect(tables.contains("message_labels"))
        #expect(tables.contains("contacts"))
        #expect(tables.contains("attachments"))
        #expect(tables.contains("email_tags"))
        #expect(tables.contains("folder_sync_state"))
        #expect(tables.contains("account_sync_state"))
    }

    @Test("v1 migration creates FTS5 virtual table")
    func v1CreatesFTS() throws {
        let db = try makeTestDatabase()
        let tables = try db.dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' AND name = 'messages_fts'
            """)
        }
        #expect(tables == ["messages_fts"])
    }

    @Test("v1 migration creates indexes")
    func v1CreatesIndexes() throws {
        let db = try makeTestDatabase()
        let indexes = try db.dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'messages_%'
                ORDER BY name
            """)
        }
        #expect(indexes.contains("messages_date"))
        #expect(indexes.contains("messages_thread_id"))
        #expect(indexes.contains("messages_sender"))
        #expect(indexes.contains("messages_prefetch"))
    }

    // Helper
    private func makeTestDatabase() throws -> MailDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try MailDatabase(accountID: "test", baseDirectory: tempDir)
    }
}
