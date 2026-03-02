import Foundation
import SQLite3

// MARK: - Error

enum AttachmentDatabaseError: Error {
    case openFailed(String)
    case schemaFailed(String)
    case queryFailed(String)
}

// MARK: - AttachmentDatabase

final class AttachmentDatabase: @unchecked Sendable {

    static let shared = AttachmentDatabase()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.serif.attachment-db", qos: .utility)

    // MARK: - Lifecycle

    private init() {
        do {
            try openDatabase()
            try createSchema()
        } catch {
            print("[AttachmentDB] Init failed: \(error)")
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Open

    private func openDatabase() throws {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("com.serif.app", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("attachment-index.sqlite").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw AttachmentDatabaseError.openFailed(msg)
        }

        // WAL mode for better concurrency
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA foreign_keys=ON")
    }

    // MARK: - Schema
    //
    // MIGRATION RULES:
    // 1. NEVER DROP the main 'attachments' table
    // 2. New columns: ALTER TABLE ADD COLUMN (silently ignored if exists)
    // 3. FTS changes: drop/recreate FTS virtual table + triggers, then rebuild from main table
    // 4. Bump PRAGMA user_version only after successful migration

    private func createSchema() throws {
        // 1. Base table
        let createTable = """
        CREATE TABLE IF NOT EXISTS attachments (
            id              TEXT PRIMARY KEY,
            messageId       TEXT NOT NULL,
            attachmentId    TEXT NOT NULL,
            filename        TEXT NOT NULL,
            mimeType        TEXT,
            fileType        TEXT,
            size            INTEGER DEFAULT 0,
            senderEmail     TEXT,
            senderName      TEXT,
            emailSubject    TEXT,
            emailDate       REAL,
            direction       TEXT DEFAULT 'received',
            indexedAt       REAL,
            indexingStatus  TEXT DEFAULT 'pending',
            extractedText   TEXT,
            embedding       BLOB
        );
        """
        if sqlite3_exec(db, createTable, nil, nil, nil) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw AttachmentDatabaseError.schemaFailed(msg)
        }

        // 2. Column migrations (silently ignored if already exist)
        sqlite3_exec(db, "ALTER TABLE attachments ADD COLUMN retryCount INTEGER DEFAULT 0", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE attachments ADD COLUMN emailBody TEXT", nil, nil, nil)

        // 3. FTS migration — rebuild when schema changes
        migrateFTS()
    }

    private func migrateFTS() {
        // Check schema version
        var version: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { version = sqlite3_column_int(stmt, 0) }
            sqlite3_finalize(stmt)
        }

        // v0 → v1: add emailBody to FTS index
        if version < 1 {
            exec("DROP TRIGGER IF EXISTS attachments_ai")
            exec("DROP TRIGGER IF EXISTS attachments_ad")
            exec("DROP TRIGGER IF EXISTS attachments_au")
            exec("DROP TABLE IF EXISTS attachments_fts")
        }

        // Create FTS + triggers (idempotent via IF NOT EXISTS)
        let fts = """
        CREATE VIRTUAL TABLE IF NOT EXISTS attachments_fts USING fts5 (
            extractedText, filename, emailSubject, emailBody,
            content='attachments', content_rowid='rowid'
        );

        CREATE TRIGGER IF NOT EXISTS attachments_ai AFTER INSERT ON attachments BEGIN
            INSERT INTO attachments_fts (rowid, extractedText, filename, emailSubject, emailBody)
            VALUES (new.rowid, new.extractedText, new.filename, new.emailSubject, new.emailBody);
        END;

        CREATE TRIGGER IF NOT EXISTS attachments_ad AFTER DELETE ON attachments BEGIN
            INSERT INTO attachments_fts (attachments_fts, rowid, extractedText, filename, emailSubject, emailBody)
            VALUES ('delete', old.rowid, old.extractedText, old.filename, old.emailSubject, old.emailBody);
        END;

        CREATE TRIGGER IF NOT EXISTS attachments_au
            AFTER UPDATE OF extractedText, filename, emailSubject, emailBody ON attachments BEGIN
            INSERT INTO attachments_fts (attachments_fts, rowid, extractedText, filename, emailSubject, emailBody)
            VALUES ('delete', old.rowid, old.extractedText, old.filename, old.emailSubject, old.emailBody);
            INSERT INTO attachments_fts (rowid, extractedText, filename, emailSubject, emailBody)
            VALUES (new.rowid, new.extractedText, new.filename, new.emailSubject, new.emailBody);
        END;
        """
        sqlite3_exec(db, fts, nil, nil, nil)

        if version < 1 {
            exec("INSERT INTO attachments_fts(attachments_fts) VALUES('rebuild')")
            exec("PRAGMA user_version = 1")
            print("[AttachmentDB] Migrated FTS to v1 (added emailBody)")
        }
    }

    // MARK: - Insert

    func insertAttachment(_ attachment: IndexedAttachment) {
        queue.sync {
            _insertAttachment(attachment)
        }
    }

    private func _insertAttachment(_ attachment: IndexedAttachment) {
        let sql = """
        INSERT OR IGNORE INTO attachments
            (id, messageId, attachmentId, filename, mimeType, fileType, size,
             senderEmail, senderName, emailSubject, emailDate, direction,
             indexedAt, indexingStatus, extractedText, emailBody)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, attachment.id)
        bindText(stmt, 2, attachment.messageId)
        bindText(stmt, 3, attachment.attachmentId)
        bindText(stmt, 4, attachment.filename)
        bindTextOrNull(stmt, 5, attachment.mimeType)
        bindText(stmt, 6, attachment.fileType)
        sqlite3_bind_int64(stmt, 7, Int64(attachment.size))
        bindTextOrNull(stmt, 8, attachment.senderEmail)
        bindTextOrNull(stmt, 9, attachment.senderName)
        bindTextOrNull(stmt, 10, attachment.emailSubject)
        if let date = attachment.emailDate {
            sqlite3_bind_double(stmt, 11, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        bindText(stmt, 12, attachment.direction.rawValue)
        if let indexedAt = attachment.indexedAt {
            sqlite3_bind_double(stmt, 13, indexedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        bindText(stmt, 14, attachment.indexingStatus.rawValue)
        bindTextOrNull(stmt, 15, attachment.extractedText)
        bindTextOrNull(stmt, 16, attachment.emailBody)

        sqlite3_step(stmt)
    }

    // MARK: - Update indexed content

    func updateIndexedContent(id: String, text: String?, embedding: [Float]?, status: IndexedAttachment.IndexingStatus) {
        queue.sync {
            let sql = """
            UPDATE attachments
            SET extractedText = ?, embedding = ?, indexingStatus = ?, indexedAt = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            bindTextOrNull(stmt, 1, text)

            if let embedding {
                let data = serializeEmbedding(embedding)
                data.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                sqlite3_bind_null(stmt, 2)
            }

            bindText(stmt, 3, status.rawValue)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
            bindText(stmt, 5, id)

            sqlite3_step(stmt)
        }
    }

    // MARK: - Update email body (enrich from full-format fetch)

    func updateEmailBody(id: String, body: String) {
        queue.sync {
            let sql = "UPDATE attachments SET emailBody = ? WHERE id = ? AND emailBody IS NULL"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, body)
            bindText(stmt, 2, id)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Exists

    func exists(id: String) -> Bool {
        queue.sync {
            let sql = "SELECT 1 FROM attachments WHERE id = ? LIMIT 1"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    // MARK: - Message-level check

    func hasMessageAttachments(messageId: String) -> Bool {
        queue.sync {
            let sql = "SELECT 1 FROM attachments WHERE messageId = ? LIMIT 1"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, messageId)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    // MARK: - Retry

    func resetFailedForRetry(maxRetries: Int) {
        queue.sync {
            let sql = "UPDATE attachments SET indexingStatus = 'pending' WHERE indexingStatus = 'failed' AND retryCount < ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(maxRetries))
            sqlite3_step(stmt)
        }
    }

    func incrementRetry(id: String) {
        queue.sync {
            let sql = "UPDATE attachments SET indexingStatus = 'failed', retryCount = retryCount + 1 WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Pending

    func pendingAttachments(limit: Int = 50) -> [IndexedAttachment] {
        queue.sync {
            let sql = """
            SELECT * FROM attachments
            WHERE indexingStatus = 'pending'
            ORDER BY emailDate DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit))
            return readRows(stmt)
        }
    }

    // MARK: - All

    func allAttachments(limit: Int = 100, offset: Int = 0) -> [IndexedAttachment] {
        queue.sync {
            let sql = """
            SELECT * FROM attachments
            ORDER BY emailDate DESC
            LIMIT ? OFFSET ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit))
            sqlite3_bind_int64(stmt, 2, Int64(offset))
            return readRows(stmt)
        }
    }

    // MARK: - FTS Search

    func searchFTS(query: String, limit: Int = 30) -> [(IndexedAttachment, Double)] {
        queue.sync {
            let sanitized = sanitizeFTSQuery(query)
            guard !sanitized.isEmpty else { return [] }

            let sql = """
            SELECT a.*, abs(bm25(attachments_fts, 1.0, 5.0, 3.0, 0.5)) AS score
            FROM attachments_fts f
            JOIN attachments a ON a.rowid = f.rowid
            WHERE attachments_fts MATCH ?
            ORDER BY score DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, 1, sanitized)
            sqlite3_bind_int64(stmt, 2, Int64(limit))

            var results: [(IndexedAttachment, Double)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let att = readRow(stmt)
                let score = sqlite3_column_double(stmt, 16)
                results.append((att, score))
            }
            return results
        }
    }

    // MARK: - All embeddings (for semantic search)

    func allEmbeddings() -> [(String, [Float])] {
        queue.sync {
            let sql = "SELECT id, embedding FROM attachments WHERE embedding IS NOT NULL"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var results: [(String, [Float])] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idRaw = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: idRaw)
                if let blobPtr = sqlite3_column_blob(stmt, 1) {
                    let byteCount = Int(sqlite3_column_bytes(stmt, 1))
                    let floats = deserializeEmbedding(blobPtr, byteCount: byteCount)
                    results.append((id, floats))
                }
            }
            return results
        }
    }

    // MARK: - By ID

    func attachment(byId id: String) -> IndexedAttachment? {
        queue.sync {
            let sql = "SELECT * FROM attachments WHERE id = ? LIMIT 1"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readRow(stmt)
        }
    }

    // MARK: - Stats

    func stats() -> (total: Int, indexed: Int, pending: Int, failed: Int) {
        queue.sync {
            let sql = """
            SELECT
                COUNT(*),
                SUM(CASE WHEN indexingStatus = 'indexed' THEN 1 ELSE 0 END),
                SUM(CASE WHEN indexingStatus = 'pending' THEN 1 ELSE 0 END),
                SUM(CASE WHEN indexingStatus = 'failed' THEN 1 ELSE 0 END)
            FROM attachments
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0, 0) }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0, 0, 0) }

            let total   = Int(sqlite3_column_int64(stmt, 0))
            let indexed = Int(sqlite3_column_int64(stmt, 1))
            let pending = Int(sqlite3_column_int64(stmt, 2))
            let failed  = Int(sqlite3_column_int64(stmt, 3))
            return (total, indexed, pending, failed)
        }
    }

    /// Distinct MIME types of unsupported attachments (for debugging).
    func unsupportedMimeTypes() -> [(mimeType: String, count: Int)] {
        queue.sync {
            let sql = """
            SELECT COALESCE(mimeType, 'unknown'), COUNT(*)
            FROM attachments
            WHERE indexingStatus = 'unsupported'
            GROUP BY mimeType
            ORDER BY COUNT(*) DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var results: [(String, Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let mime = columnText(stmt, 0) ?? "unknown"
                let count = Int(sqlite3_column_int64(stmt, 1))
                results.append((mime, count))
            }
            return results
        }
    }

    // MARK: - Storage Info

    /// Total size on disk (main DB + WAL + SHM files) in bytes.
    func databaseSizeBytes() -> Int64 {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("com.serif.app", isDirectory: true)
        let basePath = dir.appendingPathComponent("attachment-index.sqlite").path
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let filePath = basePath + suffix
            if let attrs = try? fm.attributesOfItem(atPath: filePath),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    /// Delete all rows from the attachments table and rebuild FTS.
    func clearAll() {
        queue.sync {
            exec("DELETE FROM attachments")
            exec("INSERT INTO attachments_fts(attachments_fts) VALUES('rebuild')")
            exec("VACUUM")
        }
    }

    // MARK: - Helpers: Row Mapping

    private func readRows(_ stmt: OpaquePointer?) -> [IndexedAttachment] {
        var rows: [IndexedAttachment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(readRow(stmt))
        }
        return rows
    }

    /// Maps a `SELECT *` row to `IndexedAttachment`.
    /// Column order must match the CREATE TABLE definition.
    private func readRow(_ stmt: OpaquePointer?) -> IndexedAttachment {
        let id            = columnText(stmt, 0) ?? ""
        let messageId     = columnText(stmt, 1) ?? ""
        let attachmentId  = columnText(stmt, 2) ?? ""
        let filename      = columnText(stmt, 3) ?? ""
        let mimeType      = columnText(stmt, 4)
        let fileType      = columnText(stmt, 5) ?? "other"
        let size          = Int(sqlite3_column_int64(stmt, 6))
        let senderEmail   = columnText(stmt, 7)
        let senderName    = columnText(stmt, 8)
        let emailSubject  = columnText(stmt, 9)

        var emailDate: Date?
        if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
            emailDate = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        }

        let directionRaw  = columnText(stmt, 11) ?? "received"
        let direction     = IndexedAttachment.Direction(rawValue: directionRaw) ?? .received

        var indexedAt: Date?
        if sqlite3_column_type(stmt, 12) != SQLITE_NULL {
            indexedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
        }

        let statusRaw     = columnText(stmt, 13) ?? "pending"
        let status        = IndexedAttachment.IndexingStatus(rawValue: statusRaw) ?? .pending
        let extractedText = columnText(stmt, 14)
        // Column 15 = embedding BLOB — not mapped into IndexedAttachment
        // Column 16 = retryCount — managed separately
        let emailBody     = columnText(stmt, 17)

        return IndexedAttachment(
            id: id,
            messageId: messageId,
            attachmentId: attachmentId,
            filename: filename,
            mimeType: mimeType,
            fileType: fileType,
            size: size,
            senderEmail: senderEmail,
            senderName: senderName,
            emailSubject: emailSubject,
            emailDate: emailDate,
            direction: direction,
            indexedAt: indexedAt,
            indexingStatus: status,
            extractedText: extractedText,
            emailBody: emailBody
        )
    }

    // MARK: - Helpers: SQLite Binding

    /// Bind a non-optional String using strdup so the pointer stays alive until SQLite copies it.
    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let cStr = strdup(value)
        sqlite3_bind_text(stmt, index, cStr, -1) { ptr in free(ptr) }
    }

    /// Bind an optional String — NULL if nil.
    private func bindTextOrNull(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// Read a TEXT column as optional String.
    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    /// Fire-and-forget exec (for PRAGMAs, etc).
    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    // MARK: - Helpers: FTS Query Sanitization

    /// Wraps each word in double-quotes to avoid FTS5 syntax errors.
    private func sanitizeFTSQuery(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }
            .joined(separator: " ")
    }

    // MARK: - Helpers: Embedding Serialization

    private func serializeEmbedding(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func deserializeEmbedding(_ ptr: UnsafeRawPointer, byteCount: Int) -> [Float] {
        let count = byteCount / MemoryLayout<Float>.size
        let typed = ptr.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }
}
