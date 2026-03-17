import Foundation
import Testing
import GRDB
@testable import Vik

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
        let (db, tempDir) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let mode = try db.dbPool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(mode == "wal")
    }

    @Test("enables foreign keys")
    func enablesForeignKeys() throws {
        let (db, tempDir) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fk = try db.dbPool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        #expect(fk == 1)
    }

    @Test("integrity check passes on fresh database")
    func integrityCheckPasses() throws {
        let (db, tempDir) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        #expect(try db.integrityCheck())
    }

    @Test("v1 migration creates all tables")
    func v1CreatesAllTables() throws {
        let (db, tempDir) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: tempDir) }
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
        #expect(!tables.contains("folder_sync_state"))
        #expect(tables.contains("account_sync_state"))
    }

    @Test("v1 migration creates FTS5 virtual table")
    func v1CreatesFTS() throws {
        let (db, tempDir) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let tables = try db.dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' AND name = 'messages_fts'
            """)
        }
        #expect(tables == ["messages_fts"])
    }

    @Test("v1 migration creates indexes")
    func v1CreatesIndexes() throws {
        let (db, tempDir) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: tempDir) }
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

    // Helper — returns both database and temp directory for cleanup
    private func makeTestDatabase() throws -> (MailDatabase, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let db = try MailDatabase(accountID: "test", baseDirectory: tempDir)
        return (db, tempDir)
    }
}
