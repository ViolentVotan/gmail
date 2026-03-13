import Foundation
import GRDB

/// Legacy JSON cache envelope — kept here for migration decoding only.
struct FolderCache: Codable, Sendable {
    var messages: [GmailMessage]
    var nextPageToken: String?
}

/// One-time migration from JSON file cache to GRDB database.
/// Runs on first launch after the database layer is introduced.
enum CacheMigration {
    private static let migrationKeyPrefix = "com.serif.dbMigrationCompleted"

    static func needsMigration(accountID: String) -> Bool {
        !UserDefaults.standard.bool(forKey: "\(migrationKeyPrefix).\(accountID)")
    }

    /// Migrate existing JSON cache data into the database, then mark migration complete.
    /// Fault-tolerant: individual failures are swallowed so the flag is always set.
    /// Deletes only this account's cache subdirectory after migration.
    static func migrateIfNeeded(db: MailDatabase, accountID: String) async throws {
        guard needsMigration(accountID: accountID) else { return }
        defer {
            UserDefaults.standard.set(true, forKey: "\(migrationKeyPrefix).\(accountID)")
        }

        let syncer = BackgroundSyncer(db: db)

        // Migrate labels first so message_labels foreign keys resolve
        await migrateLabels(syncer: syncer, accountID: accountID)

        // Migrate all folder caches
        await migrateMessages(syncer: syncer, accountID: accountID)

        // Migrate AI classification tags
        await migrateTags(db: db, accountID: accountID)

        // Remove only this account's cache subdirectory — other accounts may not have migrated yet.
        let accountDir = cacheBaseDir.appendingPathComponent(accountID, isDirectory: true)
        try? FileManager.default.removeItem(at: accountDir)
    }

    // MARK: - Private helpers

    private static var cacheBaseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.genyus.serif.app/mail-cache", isDirectory: true)
    }

    private static func cacheFileURL(accountID: String, folderKey: String) -> URL {
        let safe = folderKey.replacingOccurrences(of: "/", with: "_")
        return cacheBaseDir
            .appendingPathComponent(accountID, isDirectory: true)
            .appendingPathComponent("\(safe).json")
    }

    private static func migrateLabels(syncer: BackgroundSyncer, accountID: String) async {
        let url = cacheFileURL(accountID: accountID, folderKey: "_labels")
        guard let data = try? Data(contentsOf: url),
              let labels = try? JSONDecoder().decode([GmailLabel].self, from: data),
              !labels.isEmpty
        else { return }

        try? await syncer.upsertLabels(labels)
    }

    private static func migrateMessages(syncer: BackgroundSyncer, accountID: String) async {
        let accountDir = cacheBaseDir.appendingPathComponent(accountID, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: accountDir,
            includingPropertiesForKeys: nil
        ) else { return }

        // Only process folder cache files — skip meta files and the threads subdirectory
        let skipNames: Set<String> = ["_labels.json", "_tags.json"]
        let folderFiles = entries.filter { url in
            url.pathExtension == "json" && !skipNames.contains(url.lastPathComponent)
        }

        for file in folderFiles {
            guard let data = try? Data(contentsOf: file) else { continue }

            // Support both FolderCache envelope and bare [GmailMessage]
            let messages: [GmailMessage]
            if let cache = try? JSONDecoder().decode(FolderCache.self, from: data) {
                messages = cache.messages
            } else if let bare = try? JSONDecoder().decode([GmailMessage].self, from: data) {
                messages = bare
            } else {
                continue
            }

            guard !messages.isEmpty else { continue }

            // Collect all label IDs present in this batch
            let labelIds = Array(Set(messages.flatMap { $0.labelIds ?? [] }))
            try? await syncer.upsertMessages(messages, ensureLabels: labelIds)
        }
    }

    /// Removes the old JSON cache base directory only if it is empty
    /// (i.e., all per-account subdirectories have already been cleaned up by migrateIfNeeded).
    /// Safe to call after any single account finishes migration — it will not delete
    /// cache data for accounts whose migration has not yet run.
    static func cleanupOldCache() {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheBaseDir,
            includingPropertiesForKeys: nil
        )
        if contents?.isEmpty == true {
            try? FileManager.default.removeItem(at: cacheBaseDir)
        }
    }

    private static func migrateTags(db: MailDatabase, accountID: String) async {
        let url = cacheFileURL(accountID: accountID, folderKey: "_tags")
        guard let data = try? Data(contentsOf: url),
              let tags = try? JSONDecoder().decode([String: EmailTags].self, from: data),
              !tags.isEmpty
        else { return }

        let now = Date().timeIntervalSince1970
        try? await db.dbPool.write { grdb in
            for (messageId, tag) in tags {
                let record = EmailTagRecord(
                    messageId: messageId,
                    needsReply: tag.needsReply,
                    fyiOnly: tag.fyiOnly,
                    hasDeadline: tag.hasDeadline,
                    financial: tag.financial,
                    classifiedAt: now,
                    classifierVersion: nil
                )
                try record.upsert(grdb)
            }
        }
    }
}
