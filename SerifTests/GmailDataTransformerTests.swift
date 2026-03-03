import XCTest
@testable import Serif

final class GmailDataTransformerTests: XCTestCase {

    // MARK: - parseContact

    func testParseContactWithNameAndEmail() {
        let contact = GmailDataTransformer.parseContact("Alice Smith <alice@example.com>")
        XCTAssertEqual(contact.name, "Alice Smith")
        XCTAssertEqual(contact.email, "alice@example.com")
    }

    func testParseContactWithQuotedName() {
        let contact = GmailDataTransformer.parseContact("\"John Doe\" <john@example.com>")
        XCTAssertEqual(contact.name, "John Doe")
        XCTAssertEqual(contact.email, "john@example.com")
    }

    func testParseContactEmailOnly() {
        let contact = GmailDataTransformer.parseContact("plain@example.com")
        XCTAssertEqual(contact.name, "plain@example.com")
        XCTAssertEqual(contact.email, "plain@example.com")
    }

    func testParseContactEmpty() {
        let contact = GmailDataTransformer.parseContact("")
        XCTAssertEqual(contact.name, "Unknown")
        XCTAssertEqual(contact.email, "")
    }

    func testParseContactWhitespaceOnly() {
        let contact = GmailDataTransformer.parseContact("   ")
        XCTAssertEqual(contact.name, "Unknown")
        XCTAssertEqual(contact.email, "")
    }

    func testParseContactNameEmpty_UsesEmail() {
        let contact = GmailDataTransformer.parseContact("<noreply@example.com>")
        XCTAssertEqual(contact.name, "noreply@example.com")
        XCTAssertEqual(contact.email, "noreply@example.com")
    }

    // MARK: - parseContacts (multiple)

    func testParseContactsMultiple() {
        let contacts = GmailDataTransformer.parseContacts("Alice <a@a.com>, Bob <b@b.com>, charlie@c.com")
        XCTAssertEqual(contacts.count, 3)
        XCTAssertEqual(contacts[0].name, "Alice")
        XCTAssertEqual(contacts[0].email, "a@a.com")
        XCTAssertEqual(contacts[1].name, "Bob")
        XCTAssertEqual(contacts[1].email, "b@b.com")
        XCTAssertEqual(contacts[2].email, "charlie@c.com")
    }

    func testParseContactsEmpty() {
        let contacts = GmailDataTransformer.parseContacts("")
        XCTAssertTrue(contacts.isEmpty)
    }

    func testParseContactsSingle() {
        let contacts = GmailDataTransformer.parseContacts("solo@example.com")
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].email, "solo@example.com")
    }

    // MARK: - folderFor

    func testFolderForSent() {
        XCTAssertEqual(GmailDataTransformer.folderFor(labelIDs: ["SENT", "INBOX"]), .sent)
    }

    func testFolderForDraft() {
        XCTAssertEqual(GmailDataTransformer.folderFor(labelIDs: ["DRAFT"]), .drafts)
    }

    func testFolderForSpam() {
        XCTAssertEqual(GmailDataTransformer.folderFor(labelIDs: ["SPAM"]), .spam)
    }

    func testFolderForTrash() {
        XCTAssertEqual(GmailDataTransformer.folderFor(labelIDs: ["TRASH"]), .trash)
    }

    func testFolderForInboxDefault() {
        XCTAssertEqual(GmailDataTransformer.folderFor(labelIDs: ["INBOX", "UNREAD"]), .inbox)
    }

    func testFolderForEmpty() {
        XCTAssertEqual(GmailDataTransformer.folderFor(labelIDs: []), .inbox)
    }

    // MARK: - deterministicUUID

    func testDeterministicUUIDisStable() {
        let uuid1 = GmailDataTransformer.deterministicUUID(from: "18abc123def456")
        let uuid2 = GmailDataTransformer.deterministicUUID(from: "18abc123def456")
        XCTAssertEqual(uuid1, uuid2)
    }

    func testDeterministicUUIDisDifferentForDifferentIDs() {
        let uuid1 = GmailDataTransformer.deterministicUUID(from: "message_A")
        let uuid2 = GmailDataTransformer.deterministicUUID(from: "message_B")
        XCTAssertNotEqual(uuid1, uuid2)
    }

    func testDeterministicUUIDShortInput() {
        // Should not crash with very short input
        let uuid = GmailDataTransformer.deterministicUUID(from: "a")
        XCTAssertNotEqual(uuid, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    func testDeterministicUUIDEmptyInput() {
        // Should not crash with empty input
        let uuid = GmailDataTransformer.deterministicUUID(from: "")
        XCTAssertNotNil(uuid)
    }

    // MARK: - avatarColor

    func testAvatarColorIsStable() {
        let color1 = GmailDataTransformer.avatarColor(for: "test@example.com")
        let color2 = GmailDataTransformer.avatarColor(for: "test@example.com")
        XCTAssertEqual(color1, color2)
    }

    func testAvatarColorIsHexString() {
        let color = GmailDataTransformer.avatarColor(for: "user@domain.com")
        XCTAssertTrue(color.hasPrefix("#"), "Avatar color should be a hex string: \(color)")
    }

    func testAvatarColorDifferentForDifferentEmails() {
        // Not guaranteed but statistically very likely for different inputs
        let colors = Set([
            GmailDataTransformer.avatarColor(for: "a@a.com"),
            GmailDataTransformer.avatarColor(for: "b@b.com"),
            GmailDataTransformer.avatarColor(for: "c@c.com"),
            GmailDataTransformer.avatarColor(for: "d@d.com"),
            GmailDataTransformer.avatarColor(for: "e@e.com"),
            GmailDataTransformer.avatarColor(for: "f@f.com"),
            GmailDataTransformer.avatarColor(for: "g@g.com"),
            GmailDataTransformer.avatarColor(for: "h@h.com"),
        ])
        // With 8 colors in the palette and 8 inputs, we should get at least 2 distinct colors
        XCTAssertGreaterThan(colors.count, 1, "Should produce varied colors for different emails")
    }

    // MARK: - makeAttachment

    func testMakeAttachmentFromPart() {
        let part = GmailMessagePart(
            partId: "1",
            mimeType: "application/pdf",
            filename: "report.pdf",
            headers: nil,
            body: GmailMessageBody(attachmentId: "att_001", size: 524288, data: nil),
            parts: nil
        )

        let attachment = GmailDataTransformer.makeAttachment(from: part, messageId: "msg_123")
        XCTAssertEqual(attachment.name, "report.pdf")
        XCTAssertEqual(attachment.fileType, .pdf)
        XCTAssertEqual(attachment.gmailAttachmentId, "att_001")
        XCTAssertEqual(attachment.gmailMessageId, "msg_123")
        XCTAssertEqual(attachment.mimeType, "application/pdf")
        XCTAssertEqual(attachment.size, "512 KB")
    }

    func testMakeAttachmentNoFilename() {
        let part = GmailMessagePart(
            partId: "2",
            mimeType: "image/png",
            filename: nil,
            headers: nil,
            body: GmailMessageBody(attachmentId: "att_002", size: 1024, data: nil),
            parts: nil
        )

        let attachment = GmailDataTransformer.makeAttachment(from: part, messageId: "msg_456")
        XCTAssertEqual(attachment.name, "attachment")
        XCTAssertEqual(attachment.fileType, .document) // no extension -> document
    }

    func testMakeAttachmentSizeFormatting() {
        // Small file: bytes
        let smallPart = GmailMessagePart(
            partId: "1", mimeType: nil, filename: "tiny.txt", headers: nil,
            body: GmailMessageBody(attachmentId: nil, size: 500, data: nil), parts: nil
        )
        let small = GmailDataTransformer.makeAttachment(from: smallPart, messageId: "m1")
        XCTAssertEqual(small.size, "500 B")

        // Medium file: KB
        let medPart = GmailMessagePart(
            partId: "2", mimeType: nil, filename: "medium.txt", headers: nil,
            body: GmailMessageBody(attachmentId: nil, size: 51200, data: nil), parts: nil
        )
        let med = GmailDataTransformer.makeAttachment(from: medPart, messageId: "m2")
        XCTAssertEqual(med.size, "50 KB")

        // Large file: MB
        let largePart = GmailMessagePart(
            partId: "3", mimeType: nil, filename: "large.zip", headers: nil,
            body: GmailMessageBody(attachmentId: nil, size: 5_242_880, data: nil), parts: nil
        )
        let large = GmailDataTransformer.makeAttachment(from: largePart, messageId: "m3")
        XCTAssertEqual(large.size, "5.0 MB")
    }
}
