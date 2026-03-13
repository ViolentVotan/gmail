import Foundation
import Testing
import GRDB
@testable import Serif

@Suite("MessageRecord")
struct MessageRecordTests {
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
        #expect(record.isRead == false)
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

    @Test("inserts and fetches from database")
    func insertAndFetch() throws {
        let mailDB = try makeTestDatabase()
        let record = MessageRecord.fixture(gmailId: "rt-test")

        try mailDB.dbPool.write { db in
            try record.insert(db)
        }

        let all = try mailDB.dbPool.read { db in
            try MessageRecord.fetchAll(db)
        }
        #expect(all.count == 1)
        let fetched = all.first
        #expect(fetched?.gmailId == "rt-test")
        #expect(fetched?.subject == record.subject)
        #expect(fetched?.isRead == record.isRead)
        #expect(fetched?.isStarred == record.isStarred)
    }

    @Test("converts MessageRecord to Email for UI display")
    func toEmailConversion() throws {
        let db = try makeTestDatabase()
        try db.dbPool.write { db in
            try LabelRecord(gmailId: "INBOX", name: "Inbox", type: "system", bgColor: nil, textColor: nil).insert(db)
            try LabelRecord(gmailId: "work", name: "Work", type: "user", bgColor: "#4285f4", textColor: "#ffffff").insert(db)
            var msg = MessageRecord.fixture(gmailId: "m1", subject: "Test Email")
            msg.senderEmail = "alice@example.com"
            msg.senderName = "Alice"
            msg.isRead = true
            msg.isStarred = false
            msg.hasAttachments = true
            msg.threadMessageCount = 3
            try msg.insert(db)
            try MessageLabelRecord(messageId: "m1", labelId: "INBOX").insert(db)
            try MessageLabelRecord(messageId: "m1", labelId: "work").insert(db)
        }

        let email = try db.dbPool.read { db in
            let msg = try MessageRecord.fetchOne(db, key: "m1")!
            let labels = try MailDatabaseQueries.labels(forMessage: "m1", in: db)
            return msg.toEmail(labels: labels, tags: nil)
        }

        #expect(email.subject == "Test Email")
        #expect(email.sender.email == "alice@example.com")
        #expect(email.sender.name == "Alice")
        #expect(email.isRead == true)
        #expect(email.isStarred == false)
        #expect(email.hasAttachments == true)
        #expect(email.threadMessageCount == 3)
        #expect(email.labels.count == 1) // Only user labels shown (not system)
    }

    private func makeTestDatabase() throws -> MailDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try MailDatabase(accountID: "test", baseDirectory: tempDir)
    }
}
