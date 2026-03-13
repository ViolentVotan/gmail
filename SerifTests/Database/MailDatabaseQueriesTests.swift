import Testing
import GRDB
@testable import Serif

@Suite("MailDatabaseQueries")
struct MailDatabaseQueriesTests {

    @Test("inbox query returns messages with INBOX label sorted by date desc")
    func inboxQuery() throws {
        let db = try makeTestDatabase()
        try db.dbPool.write { db in
            try LabelRecord(gmailId: "INBOX", name: "Inbox", type: "system", bgColor: nil, textColor: nil).insert(db)
            try MessageRecord.fixture(gmailId: "m1", internalDate: 1000).insert(db)
            try MessageRecord.fixture(gmailId: "m2", internalDate: 2000).insert(db)
            try MessageRecord.fixture(gmailId: "m3", internalDate: 500).insert(db)
            try MessageLabelRecord(messageId: "m1", labelId: "INBOX").insert(db)
            try MessageLabelRecord(messageId: "m2", labelId: "INBOX").insert(db)
            // m3 not in INBOX
        }

        let messages = try db.dbPool.read { db in
            try MailDatabaseQueries.messagesForLabel("INBOX", limit: 50, in: db)
        }
        #expect(messages.count == 2)
        #expect(messages[0].gmailId == "m2") // newest first
        #expect(messages[1].gmailId == "m1")
    }

    @Test("thread query returns all messages in thread")
    func threadQuery() throws {
        let db = try makeTestDatabase()
        try db.dbPool.write { db in
            try MessageRecord.fixture(gmailId: "m1", threadId: "t1", internalDate: 1000).insert(db)
            try MessageRecord.fixture(gmailId: "m2", threadId: "t1", internalDate: 2000).insert(db)
            try MessageRecord.fixture(gmailId: "m3", threadId: "t2", internalDate: 3000).insert(db)
        }

        let thread = try db.dbPool.read { db in
            try MailDatabaseQueries.messagesForThread("t1", in: db)
        }
        #expect(thread.count == 2)
        #expect(thread[0].gmailId == "m1") // oldest first (ASC)
        #expect(thread[1].gmailId == "m2")
    }

    @Test("unread count for label")
    func unreadCount() throws {
        let db = try makeTestDatabase()
        try db.dbPool.write { db in
            try LabelRecord(gmailId: "INBOX", name: "Inbox", type: "system", bgColor: nil, textColor: nil).insert(db)
            var m1 = MessageRecord.fixture(gmailId: "m1"); m1.isRead = false
            var m2 = MessageRecord.fixture(gmailId: "m2"); m2.isRead = true
            var m3 = MessageRecord.fixture(gmailId: "m3"); m3.isRead = false
            try m1.insert(db); try m2.insert(db); try m3.insert(db)
            try MessageLabelRecord(messageId: "m1", labelId: "INBOX").insert(db)
            try MessageLabelRecord(messageId: "m2", labelId: "INBOX").insert(db)
            try MessageLabelRecord(messageId: "m3", labelId: "INBOX").insert(db)
        }

        let count = try db.dbPool.read { db in
            try MailDatabaseQueries.unreadCount(forLabel: "INBOX", in: db)
        }
        #expect(count == 2)
    }

    @Test("labels for message")
    func labelsForMessage() throws {
        let db = try makeTestDatabase()
        try db.dbPool.write { db in
            try LabelRecord(gmailId: "INBOX", name: "Inbox", type: "system", bgColor: nil, textColor: nil).insert(db)
            try LabelRecord(gmailId: "STARRED", name: "Starred", type: "system", bgColor: nil, textColor: nil).insert(db)
            try MessageRecord.fixture(gmailId: "m1").insert(db)
            try MessageLabelRecord(messageId: "m1", labelId: "INBOX").insert(db)
            try MessageLabelRecord(messageId: "m1", labelId: "STARRED").insert(db)
        }

        let labels = try db.dbPool.read { db in
            try MailDatabaseQueries.labels(forMessage: "m1", in: db)
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
