# Attachment Vault Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a "Dropbox for attachments" — a full-text indexed attachment explorer with hybrid keyword/semantic search, powered by a local SQLite database that indexes attachment content via background processing.

**Architecture:** Single SQLite database with FTS5 for keyword search + NaturalLanguage.framework embeddings for semantic fallback. Attachments are never stored locally — only metadata, extracted text, and embedding vectors are persisted. Gmail API provides on-demand re-download via `attachmentId`. A Swift Actor handles background indexing (download temp → extract text → index → delete temp).

**Tech Stack:** SQLite3 (C API), FTS5, Apple Vision (OCR), PDFKit, NaturalLanguage.framework, SwiftUI

---

### Task 1: Extend Attachment model with Gmail IDs

**Files:**
- Modify: `Serif/Models/Email.swift:109-120`
- Modify: `Serif/Utilities/GmailDataTransformer.swift:37-42`
- Modify: `Serif/ViewModels/MailboxViewModel.swift:470-471`

**Context:** The current `Attachment` struct has no `attachmentId` or `messageId` — we need these to re-download from Gmail and to uniquely identify attachments in our index.

**Step 1: Add Gmail fields to Attachment**

In `Serif/Models/Email.swift`, update the `Attachment` struct:

```swift
struct Attachment: Identifiable {
    let id: UUID
    let name: String
    let fileType: FileType
    let size: String
    // Gmail API identifiers for re-download
    let gmailAttachmentId: String?
    let gmailMessageId: String?
    let mimeType: String?

    init(id: UUID = UUID(), name: String, fileType: FileType = .document, size: String = "",
         gmailAttachmentId: String? = nil, gmailMessageId: String? = nil, mimeType: String? = nil) {
        self.id = id
        self.name = name
        self.fileType = fileType
        self.size = size
        self.gmailAttachmentId = gmailAttachmentId
        self.gmailMessageId = gmailMessageId
        self.mimeType = mimeType
    }
    // ... rest unchanged (FileType enum etc.)
}
```

**Step 2: Update GmailDataTransformer.makeAttachment()**

In `Serif/Utilities/GmailDataTransformer.swift:37-42`, pass the Gmail IDs and mimeType through. The method needs messageId too, so update the signature:

```swift
static func makeAttachment(from part: GmailMessagePart, messageId: String) -> Attachment {
    let name = part.filename ?? "attachment"
    let ext  = String(name.split(separator: ".").last ?? "")
    let size = part.body.map { sizeString($0.size) } ?? ""
    return Attachment(
        name: name,
        fileType: .from(fileExtension: ext),
        size: size,
        gmailAttachmentId: part.body?.attachmentId,
        gmailMessageId: messageId,
        mimeType: part.mimeType
    )
}
```

**Step 3: Update makeEmail() call site**

In `Serif/ViewModels/MailboxViewModel.swift:471`, pass the message ID:

```swift
attachments: message.attachmentParts.map { GmailDataTransformer.makeAttachment(from: $0, messageId: message.id) },
```

**Step 4: Fix any other call sites of makeAttachment**

Search for all usages of `GmailDataTransformer.makeAttachment` and update them to pass `messageId`. There may be usages in thread detail loading or elsewhere.

**Step 5: Build to verify no compile errors**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```
feat: add Gmail attachment/message IDs to Attachment model
```

---

### Task 2: Create IndexedAttachment model

**Files:**
- Create: `Serif/Models/IndexedAttachment.swift`

**Context:** This is the database model representing an indexed attachment in SQLite. Separate from the existing `Attachment` view model.

**Step 1: Create the model file**

Create `Serif/Models/IndexedAttachment.swift`:

```swift
import Foundation

struct IndexedAttachment: Identifiable {
    let id: String                  // "{messageId}_{attachmentId}"
    let messageId: String
    let attachmentId: String        // Gmail attachment ID for re-download
    let filename: String
    let mimeType: String?
    let fileType: String            // matches Attachment.FileType raw value
    let size: Int
    let senderEmail: String?
    let senderName: String?
    let emailSubject: String?
    let emailDate: Date?
    let direction: Direction
    let indexedAt: Date?
    let indexingStatus: IndexingStatus
    let extractedText: String?

    enum Direction: String {
        case received, sent
    }

    enum IndexingStatus: String {
        case pending, indexed, failed, unsupported
    }
}

struct AttachmentSearchResult: Identifiable {
    let id: String
    let attachment: IndexedAttachment
    let score: Double               // 0.0 - 1.0 relevance
    let matchSource: MatchSource

    enum MatchSource {
        case fts          // keyword match
        case semantic     // embedding similarity
        case combined     // both matched
    }
}
```

**Step 2: Add file to Xcode project and build**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
feat: add IndexedAttachment and AttachmentSearchResult models
```

---

### Task 3: Create AttachmentDatabase (SQLite wrapper)

**Files:**
- Create: `Serif/Services/AttachmentDatabase.swift`

**Context:** Low-level SQLite wrapper handling schema creation, CRUD, FTS5 indexing, and embedding storage. Uses the SQLite3 C API directly (available on macOS without dependencies).

**Step 1: Create the database service**

Create `Serif/Services/AttachmentDatabase.swift`:

```swift
import Foundation
import SQLite3

final class AttachmentDatabase {
    private var db: OpaquePointer?
    private let dbPath: String

    init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("com.serif.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("attachment-index.sqlite").path
        try open()
        try createTables()
    }

    private func open() throws {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw AttachmentDatabaseError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func createTables() throws {
        let schema = """
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

        CREATE VIRTUAL TABLE IF NOT EXISTS attachments_fts USING fts5 (
            extractedText,
            filename,
            emailSubject,
            content='attachments',
            content_rowid='rowid'
        );

        CREATE TRIGGER IF NOT EXISTS attachments_ai AFTER INSERT ON attachments BEGIN
            INSERT INTO attachments_fts(rowid, extractedText, filename, emailSubject)
            VALUES (new.rowid, new.extractedText, new.filename, new.emailSubject);
        END;

        CREATE TRIGGER IF NOT EXISTS attachments_ad AFTER DELETE ON attachments BEGIN
            INSERT INTO attachments_fts(attachments_fts, rowid, extractedText, filename, emailSubject)
            VALUES ('delete', old.rowid, old.extractedText, old.filename, old.emailSubject);
        END;

        CREATE TRIGGER IF NOT EXISTS attachments_au AFTER UPDATE OF extractedText, filename, emailSubject ON attachments BEGIN
            INSERT INTO attachments_fts(attachments_fts, rowid, extractedText, filename, emailSubject)
            VALUES ('delete', old.rowid, old.extractedText, old.filename, old.emailSubject);
            INSERT INTO attachments_fts(rowid, extractedText, filename, emailSubject)
            VALUES (new.rowid, new.extractedText, new.filename, new.emailSubject);
        END;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw AttachmentDatabaseError.schemaFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Insert / Update

    func insertAttachment(_ attachment: IndexedAttachment) throws {
        let sql = """
        INSERT OR IGNORE INTO attachments
        (id, messageId, attachmentId, filename, mimeType, fileType, size,
         senderEmail, senderName, emailSubject, emailDate, direction, indexingStatus)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AttachmentDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (attachment.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (attachment.messageId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (attachment.attachmentId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (attachment.filename as NSString).utf8String, -1, nil)
        bindOptionalText(stmt, 5, attachment.mimeType)
        bindOptionalText(stmt, 6, attachment.fileType)
        sqlite3_bind_int(stmt, 7, Int32(attachment.size))
        bindOptionalText(stmt, 8, attachment.senderEmail)
        bindOptionalText(stmt, 9, attachment.senderName)
        bindOptionalText(stmt, 10, attachment.emailSubject)
        if let date = attachment.emailDate {
            sqlite3_bind_double(stmt, 11, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        sqlite3_bind_text(stmt, 12, (attachment.direction.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 13, (attachment.indexingStatus.rawValue as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw AttachmentDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func updateIndexedContent(id: String, text: String?, embedding: [Float]?, status: IndexedAttachment.IndexingStatus) throws {
        let sql = """
        UPDATE attachments SET extractedText = ?, embedding = ?, indexingStatus = ?, indexedAt = ? WHERE id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AttachmentDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        bindOptionalText(stmt, 1, text)
        if let embedding = embedding {
            let data = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            (data as NSData).bytes.withMemoryRebound(to: UInt8.self, capacity: data.count) { ptr in
                sqlite3_bind_blob(stmt, 2, ptr, Int32(data.count), nil)
            }
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_text(stmt, 3, (status.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 5, (id as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw AttachmentDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Query

    func exists(id: String) -> Bool {
        let sql = "SELECT 1 FROM attachments WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func pendingAttachments(limit: Int = 50) throws -> [IndexedAttachment] {
        let sql = "SELECT * FROM attachments WHERE indexingStatus = 'pending' ORDER BY emailDate DESC LIMIT ?"
        return try queryAttachments(sql: sql, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
        })
    }

    func allAttachments(limit: Int = 200, offset: Int = 0) throws -> [IndexedAttachment] {
        let sql = "SELECT * FROM attachments ORDER BY emailDate DESC LIMIT ? OFFSET ?"
        return try queryAttachments(sql: sql, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
            sqlite3_bind_int(stmt, 2, Int32(offset))
        })
    }

    func searchFTS(query: String, limit: Int = 50) throws -> [(IndexedAttachment, Double)] {
        let sanitized = query.replacingOccurrences(of: "\"", with: "\"\"")
        let ftsQuery = sanitized.split(separator: " ").map { "\"\($0)\"" }.joined(separator: " ")
        let sql = """
        SELECT a.*, bm25(attachments_fts, 1.0, 5.0, 2.0) as score
        FROM attachments_fts f
        JOIN attachments a ON a.rowid = f.rowid
        WHERE attachments_fts MATCH ?
        ORDER BY score
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AttachmentDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (ftsQuery as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [(IndexedAttachment, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let att = readAttachment(from: stmt)
            let score = sqlite3_column_double(stmt, 16) // bm25 score column after all 16 attachment columns
            results.append((att, abs(score)))
        }
        return results
    }

    func allEmbeddings() throws -> [(String, [Float])] {
        let sql = "SELECT id, embedding FROM attachments WHERE embedding IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AttachmentDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(String, [Float])] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            if let blob = sqlite3_column_blob(stmt, 1) {
                let count = Int(sqlite3_column_bytes(stmt, 1)) / MemoryLayout<Float>.size
                let floats = Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: count))
                results.append((id, floats))
            }
        }
        return results
    }

    func attachment(byId id: String) throws -> IndexedAttachment? {
        let sql = "SELECT * FROM attachments WHERE id = ? LIMIT 1"
        let results = try queryAttachments(sql: sql, bind: { stmt in
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        })
        return results.first
    }

    func stats() throws -> (total: Int, indexed: Int, pending: Int, failed: Int) {
        let sql = """
        SELECT
            COUNT(*) as total,
            SUM(CASE WHEN indexingStatus = 'indexed' THEN 1 ELSE 0 END) as indexed,
            SUM(CASE WHEN indexingStatus = 'pending' THEN 1 ELSE 0 END) as pending,
            SUM(CASE WHEN indexingStatus = 'failed' THEN 1 ELSE 0 END) as failed
        FROM attachments
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AttachmentDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0, 0, 0) }
        return (
            total:   Int(sqlite3_column_int(stmt, 0)),
            indexed: Int(sqlite3_column_int(stmt, 1)),
            pending: Int(sqlite3_column_int(stmt, 2)),
            failed:  Int(sqlite3_column_int(stmt, 3))
        )
    }

    // MARK: - Helpers

    private func queryAttachments(sql: String, bind: (OpaquePointer) -> Void) throws -> [IndexedAttachment] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AttachmentDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt!)

        var results: [IndexedAttachment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readAttachment(from: stmt!))
        }
        return results
    }

    private func readAttachment(from stmt: OpaquePointer) -> IndexedAttachment {
        IndexedAttachment(
            id:             columnText(stmt, 0),
            messageId:      columnText(stmt, 1),
            attachmentId:   columnText(stmt, 2),
            filename:       columnText(stmt, 3),
            mimeType:       columnOptionalText(stmt, 4),
            fileType:       columnText(stmt, 5),
            size:           Int(sqlite3_column_int(stmt, 6)),
            senderEmail:    columnOptionalText(stmt, 7),
            senderName:     columnOptionalText(stmt, 8),
            emailSubject:   columnOptionalText(stmt, 9),
            emailDate:      sqlite3_column_type(stmt, 10) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10)) : nil,
            direction:      IndexedAttachment.Direction(rawValue: columnText(stmt, 11)) ?? .received,
            indexedAt:       sqlite3_column_type(stmt, 12) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)) : nil,
            indexingStatus: IndexedAttachment.IndexingStatus(rawValue: columnText(stmt, 13)) ?? .pending,
            extractedText:  columnOptionalText(stmt, 14)
        )
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        if let cStr = sqlite3_column_text(stmt, index) {
            return String(cString: cStr)
        }
        return ""
    }

    private func columnOptionalText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    deinit {
        sqlite3_close(db)
    }
}

enum AttachmentDatabaseError: Error {
    case openFailed(String)
    case schemaFailed(String)
    case queryFailed(String)
}
```

**Step 2: Build to verify**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
feat: add AttachmentDatabase SQLite wrapper with FTS5
```

---

### Task 4: Create ContentExtractor service

**Files:**
- Create: `Serif/Services/ContentExtractor.swift`

**Context:** Extracts text from attachment data. Uses PDFKit for PDFs, Vision for image OCR, and direct UTF-8 for text files.

**Step 1: Create the extractor**

Create `Serif/Services/ContentExtractor.swift`:

```swift
import Foundation
import PDFKit
import Vision
import NaturalLanguage

enum ContentExtractor {

    enum ExtractionResult {
        case text(String)
        case unsupported
    }

    static func extract(from data: Data, mimeType: String?, filename: String) async -> ExtractionResult {
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = mimeType?.lowercased() ?? ""

        // PDF
        if ext == "pdf" || mime == "application/pdf" {
            return extractPDF(data: data)
        }

        // Images → OCR
        if ["jpg", "jpeg", "png", "tiff", "heic", "bmp", "gif"].contains(ext)
            || mime.hasPrefix("image/") {
            return await extractOCR(data: data)
        }

        // Plain text variants
        if ["txt", "csv", "json", "xml", "html", "md", "rtf", "log",
            "swift", "py", "js", "ts", "css", "yaml", "yml", "toml", "ini", "cfg"].contains(ext)
            || mime.hasPrefix("text/") {
            return extractText(data: data)
        }

        return .unsupported
    }

    // MARK: - PDF

    private static func extractPDF(data: Data) -> ExtractionResult {
        guard let doc = PDFDocument(data: data) else { return .unsupported }
        var text = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let pageText = page.string {
                text += pageText + "\n"
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .unsupported : .text(trimmed)
    }

    // MARK: - OCR (Vision)

    private static func extractOCR(data: Data) async -> ExtractionResult {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                    continuation.resume(returning: .unsupported)
                    return
                }
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: trimmed.isEmpty ? .unsupported : .text(trimmed))
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["fr-FR", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(data: data, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: .unsupported)
            }
        }
    }

    // MARK: - Plain text

    private static func extractText(data: Data) -> ExtractionResult {
        guard let text = String(data: data, encoding: .utf8) else { return .unsupported }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .unsupported : .text(trimmed)
    }

    // MARK: - Embeddings

    static func generateEmbedding(for text: String) -> [Float]? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        // Chunk text into sentences, embed each, average
        let sentences = text.components(separatedBy: CharacterSet.newlines)
            .flatMap { $0.components(separatedBy: ". ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !sentences.isEmpty else { return nil }

        var sumVector: [Double]?
        var count = 0

        for sentence in sentences.prefix(100) { // cap at 100 sentences to avoid huge docs
            if let vec = embedding.vector(for: sentence) {
                if sumVector == nil {
                    sumVector = vec
                } else {
                    for i in 0..<vec.count {
                        sumVector![i] += vec[i]
                    }
                }
                count += 1
            }
        }

        guard let sum = sumVector, count > 0 else { return nil }
        return sum.map { Float($0 / Double(count)) }
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot   += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
feat: add ContentExtractor with PDF, OCR, text extraction and embeddings
```

---

### Task 5: Create AttachmentIndexer (background actor)

**Files:**
- Create: `Serif/Services/AttachmentIndexer.swift`

**Context:** Swift Actor that orchestrates the background indexing pipeline: detects new attachments → downloads temp → extracts text → indexes in SQLite → deletes temp. Throttled to 3 concurrent downloads.

**Step 1: Create the indexer actor**

Create `Serif/Services/AttachmentIndexer.swift`:

```swift
import Foundation

actor AttachmentIndexer {
    private let database: AttachmentDatabase
    private let messageService: GmailMessageService
    private let accountID: String
    private var isProcessing = false
    private let maxConcurrent = 3

    init(database: AttachmentDatabase, messageService: GmailMessageService, accountID: String) {
        self.database = database
        self.messageService = messageService
        self.accountID = accountID
    }

    /// Register new attachments discovered from email fetch. Inserts metadata, then triggers indexing.
    func register(attachments: [(attachment: Attachment, email: Email)]) async {
        for (att, email) in attachments {
            guard let gmailAttachmentId = att.gmailAttachmentId,
                  let gmailMessageId = att.gmailMessageId else { continue }

            let id = "\(gmailMessageId)_\(gmailAttachmentId)"
            guard !database.exists(id: id) else { continue }

            let indexed = IndexedAttachment(
                id: id,
                messageId: gmailMessageId,
                attachmentId: gmailAttachmentId,
                filename: att.name,
                mimeType: att.mimeType,
                fileType: att.fileType.rawValue,
                size: 0,
                senderEmail: email.sender.email,
                senderName: email.sender.name,
                emailSubject: email.subject,
                emailDate: email.date,
                direction: email.folder == .sent ? .sent : .received,
                indexedAt: nil,
                indexingStatus: .pending,
                extractedText: nil
            )
            try? database.insertAttachment(indexed)
        }
        await processQueue()
    }

    /// Process pending attachments in the queue
    func processQueue() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        while let pending = try? database.pendingAttachments(limit: maxConcurrent), !pending.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for att in pending {
                    group.addTask { [self] in
                        await self.indexAttachment(att)
                    }
                }
            }
        }
    }

    private func indexAttachment(_ att: IndexedAttachment) async {
        do {
            // Download from Gmail
            let data = try await messageService.getAttachment(
                messageID: att.messageId,
                attachmentID: att.attachmentId,
                accountID: accountID
            )

            // Extract text content
            let result = await ContentExtractor.extract(
                from: data,
                mimeType: att.mimeType,
                filename: att.filename
            )

            switch result {
            case .text(let text):
                let embedding = ContentExtractor.generateEmbedding(for: text)
                try database.updateIndexedContent(
                    id: att.id,
                    text: text,
                    embedding: embedding,
                    status: .indexed
                )
                print("[AttachmentIndexer] Indexed: \(att.filename)")

            case .unsupported:
                // Still index the filename for search
                try database.updateIndexedContent(
                    id: att.id,
                    text: nil,
                    embedding: nil,
                    status: .unsupported
                )
                print("[AttachmentIndexer] Unsupported format: \(att.filename)")
            }
        } catch {
            try? database.updateIndexedContent(
                id: att.id,
                text: nil,
                embedding: nil,
                status: .failed
            )
            print("[AttachmentIndexer] Failed: \(att.filename) — \(error)")
        }
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
feat: add AttachmentIndexer actor for background content indexing
```

---

### Task 6: Create AttachmentSearchService

**Files:**
- Create: `Serif/Services/AttachmentSearchService.swift`

**Context:** Implements hybrid search: FTS5 keyword search first, semantic embedding fallback if results are sparse.

**Step 1: Create the search service**

Create `Serif/Services/AttachmentSearchService.swift`:

```swift
import Foundation

struct AttachmentSearchService {
    private let database: AttachmentDatabase
    private let semanticThreshold: Int = 5  // trigger semantic if fewer FTS results

    init(database: AttachmentDatabase) {
        self.database = database
    }

    func search(query: String) throws -> [AttachmentSearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try database.allAttachments().map {
                AttachmentSearchResult(id: $0.id, attachment: $0, score: 1.0, matchSource: .fts)
            }
        }

        // Step 1: FTS keyword search
        let ftsResults = try database.searchFTS(query: query)
        let maxBM25 = ftsResults.map(\.1).max() ?? 1.0

        var resultMap: [String: AttachmentSearchResult] = [:]
        for (att, rawScore) in ftsResults {
            let normalizedScore = maxBM25 > 0 ? rawScore / maxBM25 : 1.0
            resultMap[att.id] = AttachmentSearchResult(
                id: att.id,
                attachment: att,
                score: normalizedScore,
                matchSource: .fts
            )
        }

        // Step 2: Semantic fallback if < threshold results
        if ftsResults.count < semanticThreshold {
            if let queryEmbedding = ContentExtractor.generateEmbedding(for: query) {
                let allEmbeddings = try database.allEmbeddings()
                var semanticScores: [(String, Float)] = []

                for (id, emb) in allEmbeddings {
                    let sim = ContentExtractor.cosineSimilarity(queryEmbedding, emb)
                    if sim > 0.3 { // minimum similarity threshold
                        semanticScores.append((id, sim))
                    }
                }

                semanticScores.sort { $0.1 > $1.1 }

                for (id, sim) in semanticScores.prefix(20) {
                    if let existing = resultMap[id] {
                        // Boost score if both FTS and semantic matched
                        resultMap[id] = AttachmentSearchResult(
                            id: id,
                            attachment: existing.attachment,
                            score: (existing.score + Double(sim)) / 2.0,
                            matchSource: .combined
                        )
                    } else if let att = try? database.attachment(byId: id) {
                        resultMap[id] = AttachmentSearchResult(
                            id: id,
                            attachment: att,
                            score: Double(sim),
                            matchSource: .semantic
                        )
                    }
                }
            }
        }

        return resultMap.values.sorted { $0.score > $1.score }
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
feat: add AttachmentSearchService with hybrid FTS/semantic search
```

---

### Task 7: Create AttachmentStore (ViewModel)

**Files:**
- Create: `Serif/ViewModels/AttachmentStore.swift`

**Context:** ObservableObject that bridges the database/search services to the UI. Exposes search results, indexing stats, and filters.

**Step 1: Create the store**

Create `Serif/ViewModels/AttachmentStore.swift`:

```swift
import Foundation
import Combine

@MainActor
final class AttachmentStore: ObservableObject {
    @Published var searchQuery = ""
    @Published var searchResults: [AttachmentSearchResult] = []
    @Published var allAttachments: [IndexedAttachment] = []
    @Published var stats = (total: 0, indexed: 0, pending: 0, failed: 0)
    @Published var isSearching = false
    @Published var filterFileType: Attachment.FileType?
    @Published var filterDirection: IndexedAttachment.Direction?

    private let database: AttachmentDatabase
    private let searchService: AttachmentSearchService
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    var indexer: AttachmentIndexer?

    var displayedAttachments: [AttachmentSearchResult] {
        var results = searchQuery.isEmpty
            ? allAttachments.map { AttachmentSearchResult(id: $0.id, attachment: $0, score: 1.0, matchSource: .fts) }
            : searchResults

        if let fileType = filterFileType {
            results = results.filter { $0.attachment.fileType == fileType.rawValue }
        }
        if let direction = filterDirection {
            results = results.filter { $0.attachment.direction == direction }
        }
        return results
    }

    var isIndexing: Bool { stats.pending > 0 }

    init(database: AttachmentDatabase) {
        self.database = database
        self.searchService = AttachmentSearchService(database: database)
        setupSearchDebounce()
    }

    private func setupSearchDebounce() {
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] query in
                self?.performSearch(query: query)
            }
            .store(in: &cancellables)
    }

    func refresh() {
        do {
            allAttachments = try database.allAttachments()
            stats = try database.stats()
        } catch {
            print("[AttachmentStore] refresh error: \(error)")
        }
    }

    private func performSearch(query: String) {
        searchTask?.cancel()
        searchTask = Task {
            isSearching = true
            defer { isSearching = false }
            do {
                searchResults = try searchService.search(query: query)
            } catch {
                print("[AttachmentStore] search error: \(error)")
                searchResults = []
            }
        }
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
feat: add AttachmentStore ViewModel for search and indexing state
```

---

### Task 8: Create AttachmentExplorerView (grid UI)

**Files:**
- Create: `Serif/Views/Attachments/AttachmentExplorerView.swift`
- Create: `Serif/Views/Attachments/AttachmentCardView.swift`

**Context:** The main attachment explorer that replaces ListPane + DetailPane when the Attachments folder is selected. Grid layout with search bar and filter chips.

**Step 1: Create AttachmentCardView**

Create `Serif/Views/Attachments/AttachmentCardView.swift`:

```swift
import SwiftUI

struct AttachmentCardView: View {
    let result: AttachmentSearchResult
    let isSearchActive: Bool
    @Environment(\.theme) private var theme

    private var fileTypeIcon: String {
        Attachment.FileType(rawValue: result.attachment.fileType)?.rawValue ?? "doc.fill"
    }

    private var fileTypeLabel: String {
        Attachment.FileType(rawValue: result.attachment.fileType)?.label ?? "File"
    }

    private var formattedDate: String {
        guard let date = result.attachment.emailDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(spacing: 10) {
            // File type icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.surfaceSecondary)
                    .frame(height: 80)

                Image(systemName: fileTypeIcon)
                    .font(.system(size: 28))
                    .foregroundStyle(theme.accent)
            }

            // Filename
            Text(result.attachment.filename)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // Sender + Date
            VStack(spacing: 2) {
                if let sender = result.attachment.senderName ?? result.attachment.senderEmail {
                    Text(sender)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Text(formattedDate)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textTertiary)
            }

            // Relevance score (only during search)
            if isSearchActive {
                HStack(spacing: 4) {
                    Circle()
                        .fill(scoreColor)
                        .frame(width: 6, height: 6)
                    Text("\(Int(result.score * 100))%")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    private var scoreColor: Color {
        if result.score > 0.7 { return .green }
        if result.score > 0.4 { return .orange }
        return .red
    }
}
```

**Step 2: Create AttachmentExplorerView**

Create `Serif/Views/Attachments/AttachmentExplorerView.swift`:

```swift
import SwiftUI

struct AttachmentExplorerView: View {
    @ObservedObject var store: AttachmentStore
    @Environment(\.theme) private var theme

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.divider)
            filterBar
            content
        }
        .background(theme.backgroundPrimary)
        .onAppear { store.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Attachments")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)

                Spacer()

                if store.isIndexing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("\(store.stats.indexed)/\(store.stats.total) indexed")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }
                } else if store.stats.total > 0 {
                    Text("\(store.stats.total) attachments")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            }

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.textTertiary)
                TextField("Search by content, filename, sender...", text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !store.searchQuery.isEmpty {
                    Button { store.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.surfaceSecondary)
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Filters

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // File type filters
                filterChip("All", isActive: store.filterFileType == nil) {
                    store.filterFileType = nil
                }
                ForEach(Attachment.FileType.allCases, id: \.self) { type in
                    filterChip(type.label, isActive: store.filterFileType == type) {
                        store.filterFileType = store.filterFileType == type ? nil : type
                    }
                }

                Divider().frame(height: 20)

                // Direction filters
                filterChip("Received", isActive: store.filterDirection == .received) {
                    store.filterDirection = store.filterDirection == .received ? nil : .received
                }
                filterChip("Sent", isActive: store.filterDirection == .sent) {
                    store.filterDirection = store.filterDirection == .sent ? nil : .sent
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func filterChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? theme.backgroundPrimary : theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isActive ? theme.accent : theme.surfaceSecondary)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    private var content: some View {
        Group {
            if store.displayedAttachments.isEmpty && !store.searchQuery.isEmpty {
                emptySearchState
            } else if store.allAttachments.isEmpty && !store.isIndexing {
                emptyState
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(store.displayedAttachments) { result in
                    AttachmentCardView(
                        result: result,
                        isSearchActive: !store.searchQuery.isEmpty
                    )
                    .onTapGesture {
                        // TODO: Preview attachment (re-download from Gmail)
                    }
                }
            }
            .padding(20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "paperclip")
                .font(.system(size: 40))
                .foregroundStyle(theme.textTertiary)
            Text("No attachments yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text("Attachments from your emails will appear here as they're indexed.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptySearchState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(theme.textTertiary)
            Text("No results for \"\(store.searchQuery)\"")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text("Try different keywords or check your filters.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
```

**Step 3: Build to verify**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```
feat: add AttachmentExplorerView with grid layout and search bar
```

---

### Task 9: Wire everything into ContentView

**Files:**
- Modify: `Serif/ContentView.swift:77-156` (main layout)
- Modify: `Serif/Views/EmailList/ListPaneView.swift:28-40` (remove old attachments branch)

**Context:** When `selectedFolder == .attachments`, hide ListPane + DetailPane and show AttachmentExplorerView instead. Initialize the database, indexer, and store at app level.

**Step 1: Add AttachmentStore and related properties to ContentView**

In `Serif/ContentView.swift`, add properties alongside other @StateObject declarations:

```swift
@StateObject private var attachmentStore: AttachmentStore = {
    do {
        let db = try AttachmentDatabase()
        return AttachmentStore(database: db)
    } catch {
        fatalError("Failed to initialize AttachmentDatabase: \(error)")
    }
}()
```

Also add a private property for the indexer (needs to be initialized after we have an accountID and messageService):

```swift
@State private var attachmentIndexer: AttachmentIndexer?
```

**Step 2: Modify mainLayout to conditionally show explorer**

In `Serif/ContentView.swift`, modify the `mainLayout` HStack. Wrap ListPaneView + Divider + DetailPaneView in a condition:

```swift
if selectedFolder == .attachments {
    AttachmentExplorerView(store: attachmentStore)
} else {
    ListPaneView(
        // ... existing params unchanged
    )

    Divider().background(themeManager.currentTheme.divider)

    DetailPaneView(
        // ... existing params unchanged
    )
}
```

**Step 3: Remove old attachments branch from ListPaneView**

In `Serif/Views/EmailList/ListPaneView.swift:28-40`, the `if selectedFolder == .attachments` branch is no longer needed since ContentView handles it. Remove it — the body just shows `emailList` always:

```swift
var body: some View {
    emailList
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
}
```

**Step 4: Hook indexer into email fetch flow**

In `Serif/ViewModels/MailboxViewModel.swift`, after `makeEmail()` converts messages, register new attachments with the indexer. Add a public property:

```swift
var attachmentIndexer: AttachmentIndexer?
```

In the fetch completion (after emails are populated), add:

```swift
// After self.messages = fetchedMessages (wherever the fetch completes)
if let indexer = attachmentIndexer {
    let pairs = self.emails.flatMap { email in
        email.attachments.map { (attachment: $0, email: email) }
    }
    Task { await indexer.register(attachments: pairs) }
}
```

**Step 5: Initialize indexer when account is available**

In `Serif/ContentView.swift`, in the appropriate `.onAppear` or `.onChange(of: accountID)`, create the indexer:

```swift
.onChange(of: accountID) { newID in
    guard !newID.isEmpty else { return }
    do {
        let db = try AttachmentDatabase()
        let indexer = AttachmentIndexer(
            database: db,
            messageService: GmailMessageService(apiClient: mailboxViewModel.apiClient),
            accountID: newID
        )
        attachmentIndexer = indexer
        mailboxViewModel.attachmentIndexer = indexer
        // Process any pending items from previous sessions
        Task { await indexer.processQueue() }
    } catch {
        print("[ContentView] Failed to init indexer: \(error)")
    }
}
```

Note: The exact property names for `apiClient` and service initialization need to match what already exists in the codebase. Check `MailboxViewModel` for how `GmailMessageService` is created/stored and mirror that pattern.

**Step 6: Build to verify**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```
feat: wire AttachmentExplorerView into ContentView layout
```

---

### Task 10: Build, test end-to-end, fix issues

**Files:**
- Any files that need fixes from integration

**Step 1: Full build**

Run: `xcodebuild -project Serif.xcodeproj -scheme Serif -configuration Debug build 2>&1 | tail -40`
Fix any compilation errors.

**Step 2: Launch and test**

Open the built app and verify:
1. Normal email folders still work (inbox, sent, etc.)
2. Clicking "Attachments" in sidebar shows the new explorer view
3. The search bar is visible and responsive
4. Filter chips work
5. Check console for indexer logs

**Step 3: Fix any runtime issues**

Debug and fix any issues discovered during testing.

**Step 4: Final commit**

```
fix: resolve integration issues for attachment vault
```
