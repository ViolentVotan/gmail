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

    /// Runs schema migrations.
    /// Called once, only for the instance that wins the `shared(for:)` race.
    private func migrate() throws {
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

    /// Per-account migration state: tracks whether a migration is in progress
    /// and holds the result (success or failure) once complete.
    /// - `.inProgress`: migration running, waiters accumulate continuations
    /// - `.failed`: migration failed with this error — late arrivals get the error directly
    private enum MigrationEntry {
        case inProgress([CheckedContinuation<MailDatabase, any Error>])
        case failed(any Error)
    }

    private static let migrationState = Mutex<[String: MigrationEntry]>([:])

    /// Returns a cached `MailDatabase` for the given account, creating one if needed.
    /// Avoids opening redundant `DatabasePool` connections across Intents and extensions.
    /// Uses per-account locking so that migration for one account doesn't block access
    /// to other accounts' already-cached instances.
    static func shared(for accountID: String) async throws -> MailDatabase {
        // Fast path: return cached instance without migration overhead.
        if let existing = instances.withLock({ $0[accountID] }) {
            return existing
        }

        // Ensure only one caller migrates a given account at a time.
        // If another caller is already migrating, suspend via continuation
        // and resume when the migrating caller finishes.
        enum ClaimResult {
            case migrate
            case wait
            case failed(any Error)
        }
        let claim = migrationState.withLock { state -> ClaimResult in
            if let entry = state[accountID] {
                switch entry {
                case .inProgress:
                    return .wait
                case .failed(let error):
                    return .failed(error)
                }
            }
            // Claim migration by creating the waiters entry (empty = we own it).
            state[accountID] = .inProgress([])
            return .migrate
        }

        switch claim {
        case .failed(let error):
            throw error

        case .wait:
            // Another caller is migrating — suspend until it finishes.
            return try await withCheckedThrowingContinuation { continuation in
                enum Resolution {
                    case cached(MailDatabase)
                    case waiting
                    case failed(any Error)
                }
                // Read from instances BEFORE entering the migrationState lock
                // to avoid nesting instances.withLock inside migrationState.withLock.
                let cachedInstance = instances.withLock { $0[accountID] }
                let resolution = migrationState.withLock { state -> Resolution in
                    if let entry = state[accountID] {
                        switch entry {
                        case .inProgress(var waiters):
                            // Migration still in progress — store continuation for later resume.
                            waiters.append(continuation)
                            state[accountID] = .inProgress(waiters)
                            return .waiting
                        case .failed(let error):
                            return .failed(error)
                        }
                    }
                    // Migration finished between our initial check and here.
                    if let db = cachedInstance {
                        return .cached(db)
                    }
                    // Should not happen — migration removes entry only after caching or storing error.
                    struct MigrationStateError: Error, CustomStringConvertible {
                        let description: String
                    }
                    return .failed(MigrationStateError(description: "Migration state inconsistency for \(accountID)"))
                }
                switch resolution {
                case .cached(let db):
                    continuation.resume(returning: db)
                case .waiting:
                    break // continuation stored, will be resumed by the migrating caller
                case .failed(let error):
                    continuation.resume(throwing: error)
                }
            }

        case .migrate:
            break
        }

        // Create and migrate outside the instances lock.
        do {
            let db = try MailDatabase(accountID: accountID, skipMigrations: true)
            try db.migrate()

            // Store in instances BEFORE resuming waiters so they always find the instance.
            instances.withLock { $0[accountID] = db }
            let waiters: [CheckedContinuation<MailDatabase, any Error>] = migrationState.withLock {
                if case .inProgress(let w) = $0.removeValue(forKey: accountID) { return w }
                return []
            }
            for waiter in waiters {
                waiter.resume(returning: db)
            }

            // Run PRAGMA optimize in the background — can be slow on large databases
            // and must not block the initial database access on every app launch.
            Task.detached(priority: .utility) {
                try? await db.dbPool.write { try $0.execute(sql: "PRAGMA optimize") }
            }

            return db
        } catch {
            // Store the error so late-arriving callers get it directly instead of retrying.
            let waiters: [CheckedContinuation<MailDatabase, any Error>] = migrationState.withLock {
                let entry = $0[accountID]
                $0[accountID] = .failed(error)
                if case .inProgress(let w) = entry { return w }
                return []
            }
            for waiter in waiters {
                waiter.resume(throwing: error)
            }
            throw error
        }
    }
}
