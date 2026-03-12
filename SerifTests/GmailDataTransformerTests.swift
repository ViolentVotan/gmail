import Testing
import Foundation
@testable import Serif

@Suite struct GmailDataTransformerTests {

    // MARK: - parseContact

    @Test func parseContactWithNameAndEmail() {
        let contact = GmailDataTransformer.parseContact("Alice Smith <alice@example.com>")
        #expect(contact.name == "Alice Smith")
        #expect(contact.email == "alice@example.com")
    }

    @Test func parseContactWithQuotedName() {
        let contact = GmailDataTransformer.parseContact("\"John Doe\" <john@example.com>")
        #expect(contact.name == "John Doe")
        #expect(contact.email == "john@example.com")
    }

    @Test func parseContactEmailOnly() {
        let contact = GmailDataTransformer.parseContact("plain@example.com")
        #expect(contact.name == "plain@example.com")
        #expect(contact.email == "plain@example.com")
    }

    @Test func parseContactEmpty() {
        let contact = GmailDataTransformer.parseContact("")
        #expect(contact.name == "Unknown")
        #expect(contact.email == "")
    }

    @Test func parseContactWhitespaceOnly() {
        let contact = GmailDataTransformer.parseContact("   ")
        #expect(contact.name == "Unknown")
        #expect(contact.email == "")
    }

    @Test func parseContactNameEmpty_UsesEmail() {
        let contact = GmailDataTransformer.parseContact("<noreply@example.com>")
        #expect(contact.name == "noreply@example.com")
        #expect(contact.email == "noreply@example.com")
    }

    // MARK: - parseContacts (multiple)

    @Test func parseContactsMultiple() {
        let contacts = GmailDataTransformer.parseContacts("Alice <a@a.com>, Bob <b@b.com>, charlie@c.com")
        #expect(contacts.count == 3)
        #expect(contacts[0].name == "Alice")
        #expect(contacts[0].email == "a@a.com")
        #expect(contacts[1].name == "Bob")
        #expect(contacts[1].email == "b@b.com")
        #expect(contacts[2].email == "charlie@c.com")
    }

    @Test func parseContactsEmpty() {
        let contacts = GmailDataTransformer.parseContacts("")
        #expect(contacts.isEmpty)
    }

    @Test func parseContactsSingle() {
        let contacts = GmailDataTransformer.parseContacts("solo@example.com")
        #expect(contacts.count == 1)
        #expect(contacts[0].email == "solo@example.com")
    }

    // MARK: - folderFor

    @Test(arguments: [
        (["SENT", "INBOX"], Folder.sent),
        (["DRAFT"], Folder.drafts),
        (["SPAM"], Folder.spam),
        (["TRASH"], Folder.trash),
        (["INBOX", "UNREAD"], Folder.inbox),
        ([], Folder.inbox),
    ] as [([String], Folder)])
    func folderForLabelIDs(labelIDs: [String], expected: Folder) {
        #expect(GmailDataTransformer.folderFor(labelIDs: labelIDs) == expected)
    }

    // MARK: - deterministicUUID

    @Test func deterministicUUIDisStable() {
        let uuid1 = GmailDataTransformer.deterministicUUID(from: "18abc123def456")
        let uuid2 = GmailDataTransformer.deterministicUUID(from: "18abc123def456")
        #expect(uuid1 == uuid2)
    }

    @Test func deterministicUUIDisDifferentForDifferentIDs() {
        let uuid1 = GmailDataTransformer.deterministicUUID(from: "message_A")
        let uuid2 = GmailDataTransformer.deterministicUUID(from: "message_B")
        #expect(uuid1 != uuid2)
    }

    @Test func deterministicUUIDShortInput() {
        // Should not crash with very short input
        let uuid = GmailDataTransformer.deterministicUUID(from: "a")
        #expect(uuid != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    @Test func deterministicUUIDEmptyInput() {
        // Should not crash with empty input
        let uuid = GmailDataTransformer.deterministicUUID(from: "")
        #expect(uuid != nil)
    }

    // MARK: - avatarColor

    @Test func avatarColorIsStable() {
        let color1 = GmailDataTransformer.avatarColor(for: "test@example.com")
        let color2 = GmailDataTransformer.avatarColor(for: "test@example.com")
        #expect(color1 == color2)
    }

    @Test func avatarColorIsHexString() {
        let color = GmailDataTransformer.avatarColor(for: "user@domain.com")
        #expect(color.hasPrefix("#"), "Avatar color should be a hex string: \(color)")
    }

    @Test func avatarColorDifferentForDifferentEmails() {
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
        #expect(colors.count > 1, "Should produce varied colors for different emails")
    }

    // MARK: - makeAttachment

    @Test func makeAttachmentFromPart() {
        let part = GmailMessagePart(
            partId: "1",
            mimeType: "application/pdf",
            filename: "report.pdf",
            headers: nil,
            body: GmailMessageBody(attachmentId: "att_001", size: 524288, data: nil),
            parts: nil
        )

        let attachment = GmailDataTransformer.makeAttachment(from: part, messageId: "msg_123")
        #expect(attachment.name == "report.pdf")
        #expect(attachment.fileType == .pdf)
        #expect(attachment.gmailAttachmentId == "att_001")
        #expect(attachment.gmailMessageId == "msg_123")
        #expect(attachment.mimeType == "application/pdf")
        #expect(attachment.size == "512 KB")
    }

    @Test func makeAttachmentNoFilename() {
        let part = GmailMessagePart(
            partId: "2",
            mimeType: "image/png",
            filename: nil,
            headers: nil,
            body: GmailMessageBody(attachmentId: "att_002", size: 1024, data: nil),
            parts: nil
        )

        let attachment = GmailDataTransformer.makeAttachment(from: part, messageId: "msg_456")
        #expect(attachment.name == "attachment")
        #expect(attachment.fileType == .document) // no extension -> document
    }

    @Test(arguments: [
        (500, "500 B"),
        (51200, "50 KB"),
        (5_242_880, "5.0 MB"),
    ] as [(Int, String)])
    func makeAttachmentSizeFormatting(size: Int, expected: String) {
        let part = GmailMessagePart(
            partId: "1", mimeType: nil, filename: "file.txt", headers: nil,
            body: GmailMessageBody(attachmentId: nil, size: size, data: nil), parts: nil
        )
        let attachment = GmailDataTransformer.makeAttachment(from: part, messageId: "m1")
        #expect(attachment.size == expected)
    }
}
