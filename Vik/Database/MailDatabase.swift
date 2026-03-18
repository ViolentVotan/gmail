import Foundation
internal import GRDB
import Synchronization

/// Per-account SQLite database using GRDB DatabasePool (WAL mode).
/// Each account has its own database file for isolation.
final class MailDatabase: Sendable {
    let dbPool: DatabasePool
    let accountID: String

    /// Default base directory for mail databases.
    static var defaultBaseDirectory: URL {
        AppPaths.appSupportDirectory
            .appendingPathComponent("mail-db", isDirectory: true)
    }

    /// Creates or opens the database for the given account and runs migrations.
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
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA cache_size = -64000")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 400")
        }
        // SQL tracing available via GRDB_TRACE environment variable

        dbPool = try DatabasePool(path: path, configuration: config)
        try MailDatabaseMigrations.migrator.migrate(dbPool)
        // Run PRAGMA optimize once per open to help SQLite's query planner
        // maintain optimal index statistics without manual ANALYZE.
        try dbPool.write { db in
            try db.execute(sql: "PRAGMA optimize")
        }
    }

    /// Opens the database pool without running migrations.
    /// Used exclusively by `shared(for:)` so that only the winning instance migrates,
    /// preventing `close()` from interrupting an in-flight migration on the losing instance.
    private init(accountID: String, baseDirectory: URL? = nil, skipMigrations: Bool) throws {
        self.accountID = accountID
        let dir = baseDirectory ?? Self.defaultBaseDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("\(accountID).sqlite").path

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA cache_size = -64000")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 400")
        }

        dbPool = try DatabasePool(path: path, configuration: config)
    }

    /// Runs schema migrations and PRAGMA optimize.
    /// Called once, only for the instance that wins the `shared(for:)` race.
    private func migrate() throws {
        try MailDatabaseMigrations.migrator.migrate(dbPool)
        try dbPool.write { db in
            try db.execute(sql: "PRAGMA optimize")
        }
    }

    /// Returns true if the database passes SQLite integrity check.
    func integrityCheck() throws -> Bool {
        try dbPool.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            return result == "ok"
        }
    }

    /// Closes the database pool, releasing all connections.
    /// Performs a WAL checkpoint before closing to reclaim WAL file space.
    /// Call this before `deleteDatabase(accountID:baseDirectory:)` to avoid WAL/SHM file locks.
    func close() {
        try? dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try? dbPool.close()
    }

    /// Removes a cached instance for the given account and closes its database connections.
    /// Call on sign-out to ensure the `instances` cache doesn't hold stale DB connections.
    static func evict(accountID: String) {
        let removed = instances.withLock { $0.removeValue(forKey: accountID) }
        removed?.close()
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
    private static let migrating = Mutex<Set<String>>([])

    /// Returns a cached `MailDatabase` for the given account, creating one if needed.
    /// Avoids opening redundant `DatabasePool` connections across Intents and extensions.
    /// Uses per-account locking so that migration for one account doesn't block access
    /// to other accounts' already-cached instances.
    static func shared(for accountID: String) throws -> MailDatabase {
        // Fast path: return cached instance without migration overhead.
        if let existing = instances.withLock({ $0[accountID] }) {
            return existing
        }

        // Ensure only one caller migrates a given account at a time.
        // If another thread is already migrating this account, spin until it finishes
        // and then return the cached result.
        let didClaim = migrating.withLock { $0.insert(accountID).inserted }
        guard didClaim else {
            // Another thread is migrating — wait for it to finish and cache the result.
            while migrating.withLock({ $0.contains(accountID) }) {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let cached = instances.withLock({ $0[accountID] }) else {
                // The other thread failed; retry from scratch.
                return try shared(for: accountID)
            }
            return cached
        }

        defer { _ = migrating.withLock { $0.remove(accountID) } }

        // Create and migrate outside the instances lock.
        let db = try MailDatabase(accountID: accountID, skipMigrations: true)
        try db.migrate()

        instances.withLock { $0[accountID] = db }
        return db
    }
}
