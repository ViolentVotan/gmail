import Foundation
import Testing
import GRDB
@testable import Serif

@Suite("BackgroundSyncer")
struct BackgroundSyncerTests {

    @Test("upsertMessages inserts new messages and labels into DB")
    func upsertMessages() async throws {
        let db = try makeTestDatabase()
        let syncer = BackgroundSyncer(db: db)

        // Simulate API response
        let messages = [
            GmailMessage.testFixture(id: "m1", threadId: "t1", labelIds: ["INBOX", "UNREAD"], subject: "Hello"),
            GmailMessage.testFixture(id: "m2", threadId: "t1", labelIds: ["INBOX"], subject: "Re: Hello"),
        ]

        try await syncer.upsertMessages(messages, ensureLabels: ["INBOX", "UNREAD"])

        let count = try await db.dbPool.read { db in
            try MessageRecord.fetchCount(db)
        }
        #expect(count == 2)

        let inboxCount = try await db.dbPool.read { db in
            try MailDatabaseQueries.messagesForLabel("INBOX", in: db).count
        }
        #expect(inboxCount == 2)
    }

    @Test("upsertMessages updates existing message on re-sync")
    func upsertUpdatesExisting() async throws {
        let db = try makeTestDatabase()
        let syncer = BackgroundSyncer(db: db)

        let msg1 = GmailMessage.testFixture(id: "m1", threadId: "t1", labelIds: ["INBOX", "UNREAD"], subject: "Original")
        try await syncer.upsertMessages([msg1], ensureLabels: ["INBOX", "UNREAD"])

        let msg1Updated = GmailMessage.testFixture(id: "m1", threadId: "t1", labelIds: ["INBOX"], subject: "Original")
        try await syncer.upsertMessages([msg1Updated], ensureLabels: ["INBOX"])

        let fetched = try await db.dbPool.read { db in
            try MessageRecord.fetchOne(db, key: "m1")
        }
        #expect(fetched?.isRead == true)  // UNREAD removed
    }

    @Test("updateThreadMessageCounts sets correct counts")
    func threadCounts() async throws {
        let db = try makeTestDatabase()
        let syncer = BackgroundSyncer(db: db)

        let messages = [
            GmailMessage.testFixture(id: "m1", threadId: "t1", labelIds: ["INBOX"], subject: "A"),
            GmailMessage.testFixture(id: "m2", threadId: "t1", labelIds: ["INBOX"], subject: "B"),
            GmailMessage.testFixture(id: "m3", threadId: "t2", labelIds: ["INBOX"], subject: "C"),
        ]
        try await syncer.upsertMessages(messages, ensureLabels: ["INBOX"])

        let m1 = try await db.dbPool.read { db in try MessageRecord.fetchOne(db, key: "m1") }
        let m3 = try await db.dbPool.read { db in try MessageRecord.fetchOne(db, key: "m3") }
        #expect(m1?.threadMessageCount == 2)
        #expect(m3?.threadMessageCount == 1)
    }

    @Test("applyDelta inserts new messages and removes deleted ones")
    func applyDelta() async throws {
        let db = try makeTestDatabase()
        let syncer = BackgroundSyncer(db: db)

        // Seed existing messages
        let existing = [
            GmailMessage.testFixture(id: "m1", threadId: "t1", labelIds: ["INBOX"]),
            GmailMessage.testFixture(id: "m2", threadId: "t2", labelIds: ["INBOX"]),
        ]
        try await syncer.upsertMessages(existing, ensureLabels: ["INBOX"])

        // Apply delta: m3 added, m1 deleted, m2 labels changed
        let newMessages = [GmailMessage.testFixture(id: "m3", threadId: "t3", labelIds: ["INBOX"])]
        let deletedIds = ["m1"]
        let labelUpdates: [(gmailId: String, labelIds: [String])] = [("m2", ["INBOX", "STARRED"])]

        try await syncer.applyDelta(
            newMessages: newMessages,
            deletedIds: deletedIds,
            labelUpdates: labelUpdates
        )

        let count = try await db.dbPool.read { db in try MessageRecord.fetchCount(db) }
        #expect(count == 2) // m2, m3 (m1 deleted)

        let m2 = try await db.dbPool.read { db in try MessageRecord.fetchOne(db, key: "m2") }
        #expect(m2?.isStarred == true)
    }

    private func makeTestDatabase() throws -> MailDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try MailDatabase(accountID: "test", baseDirectory: tempDir)
    }
}
