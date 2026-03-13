import Testing
import GRDB
@testable import Serif

@Suite("FTSManager")
struct FTSManagerTests {
    @Test("indexes message and finds via search")
    func indexAndSearch() throws {
        let db = try makeTestDatabase()
        var msg = MessageRecord.fixture(gmailId: "m1", subject: "Invoice from Acme Corp")
        msg.bodyPlain = "Please find attached your invoice for March 2026."
        msg.senderName = "Billing Department"
        msg.senderEmail = "billing@acme.com"

        try db.dbPool.write { db in
            try msg.insert(db)
            try FTSManager.index(message: msg, in: db)
        }

        let results = try db.dbPool.read { db in
            try FTSManager.search(query: "invoice", in: db)
        }
        #expect(results.count == 1)
        #expect(results[0].gmailId == "m1")
    }

    @Test("update replaces old FTS content")
    func updateReplacesContent() throws {
        let db = try makeTestDatabase()
        var msg = MessageRecord.fixture(gmailId: "m1", subject: "Old Subject")
        msg.bodyPlain = "old content"

        try db.dbPool.write { db in
            try msg.insert(db)
            try FTSManager.index(message: msg, in: db)
        }

        msg.subject = "New Subject"
        msg.bodyPlain = "completely new content"

        try db.dbPool.write { db in
            try msg.upsert(db)
            try FTSManager.update(message: msg, in: db)
        }

        let oldResults = try db.dbPool.read { db in
            try FTSManager.search(query: "old", in: db)
        }
        #expect(oldResults.isEmpty)

        let newResults = try db.dbPool.read { db in
            try FTSManager.search(query: "new", in: db)
        }
        #expect(newResults.count == 1)
    }

    @Test("delete removes from FTS index")
    func deleteRemoves() throws {
        let db = try makeTestDatabase()
        var msg = MessageRecord.fixture(gmailId: "m1", subject: "Searchable")

        try db.dbPool.write { db in
            try msg.insert(db)
            try FTSManager.index(message: msg, in: db)
        }
        try db.dbPool.write { db in
            try FTSManager.delete(gmailId: "m1", in: db)
        }

        let results = try db.dbPool.read { db in
            try FTSManager.search(query: "Searchable", in: db)
        }
        #expect(results.isEmpty)
    }

    @Test("evict nulls body but keeps subject searchable")
    func evictKeepsSubject() throws {
        let db = try makeTestDatabase()
        var msg = MessageRecord.fixture(gmailId: "m1", subject: "Important Meeting")
        msg.bodyPlain = "Let's discuss the quarterly results"

        try db.dbPool.write { db in
            try msg.insert(db)
            try FTSManager.index(message: msg, in: db)
        }

        try db.dbPool.write { db in
            try FTSManager.evictBody(gmailId: "m1", subject: "Important Meeting", snippet: msg.snippet, senderName: msg.senderName, senderEmail: msg.senderEmail, in: db)
        }

        let bodyResults = try db.dbPool.read { db in
            try FTSManager.search(query: "quarterly", in: db)
        }
        #expect(bodyResults.isEmpty)

        let subjectResults = try db.dbPool.read { db in
            try FTSManager.search(query: "Meeting", in: db)
        }
        #expect(subjectResults.count == 1)
    }

    private func makeTestDatabase() throws -> MailDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try MailDatabase(accountID: "test", baseDirectory: tempDir)
    }
}
