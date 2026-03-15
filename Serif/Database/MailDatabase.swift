import Foundation
import GRDB
import Synchronization

/// Per-account SQLite database using GRDB DatabasePool (WAL mode).
/// Each account has its own database file for isolation.
final class MailDatabase: Sendable {
    let dbPool: DatabasePool
    let accountID: String

    /// Default base directory for mail databases.
    static var defaultBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vikingz.serif.app/mail-db", isDirectory: true)
    }

    /// Creates or opens the database for the given account.
    /// - Parameters:
    ///   - accountID: The Gmail account identifier (email address).
    ///   - baseDirectory: Override for testing. Defaults to Application Support.
    init(accountID: String, baseDirectory: URL? = nil) throws {
        self.accountID = accountID
        let dir = baseDirectory ?? Self.defaultBaseDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("\(accountID).sqlite").path

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA cache_size = -64000")
        }
        // SQL tracing available via GRDB_TRACE environment variable

        dbPool = try DatabasePool(path: path, configuration: config)
        try MailDatabaseMigrations.migrator.migrate(dbPool)
    }

    /// Returns true if the database passes SQLite integrity check.
    func integrityCheck() throws -> Bool {
        try dbPool.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            return result == "ok"
        }
    }

    /// Closes the database pool, releasing all connections.
    /// Call this before `deleteDatabase(accountID:baseDirectory:)` to avoid WAL/SHM file locks.
    func close() {
        try? dbPool.close()
    }

    /// Deletes the database file and WAL/SHM files.
    /// Removes any cached shared instance, then deletes the on-disk SQLite, WAL, and SHM files.
    static func deleteDatabase(accountID: String, baseDirectory: URL? = nil) {
        let existing = instances.withLock { $0.removeValue(forKey: accountID) }
        existing?.close()

        let dir = baseDirectory ?? defaultBaseDirectory
        let base = dir.appendingPathComponent("\(accountID).sqlite").path
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: base + suffix)
        }
    }

    // MARK: - Shared Instance Cache

    private static let instances = Mutex<[String: MailDatabase]>([:])

    /// Returns a cached `MailDatabase` for the given account, creating one if needed.
    /// Avoids opening redundant `DatabasePool` connections across Intents and extensions.
    static func shared(for accountID: String) throws -> MailDatabase {
        try instances.withLock { cache in
            if let existing = cache[accountID] { return existing }
            let db = try MailDatabase(accountID: accountID)
            cache[accountID] = db
            return db
        }
    }
}
