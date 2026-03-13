import Testing
import GRDB
@testable import Serif

@Suite("MessageRecord")
struct MessageRecordTests {
    @Test("round-trips through database")
    func roundTrip() throws {
        let db = try makeTestDatabase()
        var record = MessageRecord.fixture()

        try db.dbPool.write { db in
            try record.insert(db)
        }

        let fetched = try db.dbPool.read { db in
            try MessageRecord.fetchOne(db, key: record.gmailId)
        }
        #expect(fetched?.gmailId == record.gmailId)
        #expect(fetched?.threadId == record.threadId)
        #expect(fetched?.subject == record.subject)
        #expect(fetched?.isRead == false)
        #expect(fetched?.isStarred == false)
    }

    @Test("upsert updates existing record")
    func upsertUpdates() throws {
        let db = try makeTestDatabase()
        var record = MessageRecord.fixture()

        try db.dbPool.write { db in
            try record.insert(db)
        }

        record.subject = "Updated Subject"
        record.isRead = true

        try db.dbPool.write { db in
            try record.upsert(db)
        }

        let fetched = try db.dbPool.read { db in
            try MessageRecord.fetchOne(db, key: record.gmailId)
        }
        #expect(fetched?.subject == "Updated Subject")
        #expect(fetched?.isRead == true)
    }

    @Test("converts from GmailMessage")
    func convertsFromGmailMessage() throws {
        let gmail = GmailMessage.testFixture(
            id: "msg-1",
            threadId: "thread-1",
            labelIds: ["INBOX", "UNREAD"],
            subject: "Test Subject",
            from: "sender@test.com",
            snippet: "Hello world"
        )
        let record = MessageRecord(from: gmail)
        #expect(record.gmailId == "msg-1")
        #expect(record.threadId == "thread-1")
        #expect(record.subject == "Test Subject")
        #expect(record.senderEmail == "sender@test.com")
        #expect(record.isRead == false)  // UNREAD label present
        #expect(record.isStarred == false)
    }

    @Test("queries messages by thread_id")
    func queryByThread() throws {
        let db = try makeTestDatabase()
        try db.dbPool.write { db in
            try MessageRecord.fixture(gmailId: "m1", threadId: "t1").insert(db)
            try MessageRecord.fixture(gmailId: "m2", threadId: "t1").insert(db)
            try MessageRecord.fixture(gmailId: "m3", threadId: "t2").insert(db)
        }

        let thread = try db.dbPool.read { db in
            try MessageRecord
                .filter(Column("thread_id") == "t1")
                .order(Column("internal_date").asc)
                .fetchAll(db)
        }
        #expect(thread.count == 2)
        #expect(thread.allSatisfy { $0.threadId == "t1" })
    }

    @Test("message-label association works")
    func messageLabelAssociation() throws {
        let db = try makeTestDatabase()
        try db.dbPool.write { db in
            try LabelRecord(gmailId: "INBOX", name: "Inbox", type: "system", bgColor: nil, textColor: nil).insert(db)
            try LabelRecord(gmailId: "STARRED", name: "Starred", type: "system", bgColor: nil, textColor: nil).insert(db)
            try MessageRecord.fixture(gmailId: "m1").insert(db)
            try MessageLabelRecord(messageId: "m1", labelId: "INBOX").insert(db)
            try MessageLabelRecord(messageId: "m1", labelId: "STARRED").insert(db)
        }

        let labels = try db.dbPool.read { db in
            let msg = try MessageRecord.fetchOne(db, key: "m1")!
            return try msg.request(for: MessageRecord.labels).fetchAll(db)
        }
        #expect(labels.count == 2)
    }

    private func makeTestDatabase() throws -> MailDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try MailDatabase(accountID: "test", baseDirectory: tempDir)
    }
}
