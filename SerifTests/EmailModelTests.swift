import XCTest
@testable import Serif

final class EmailModelTests: XCTestCase {

    // MARK: - Contact

    func testContactInitials_TwoWords() {
        let contact = Contact(name: "Alice Smith", email: "alice@example.com")
        XCTAssertEqual(contact.initials, "AS")
    }

    func testContactInitials_ThreeWords() {
        let contact = Contact(name: "John Michael Doe", email: "jmd@example.com")
        // Should use first letter of first two words
        XCTAssertEqual(contact.initials, "JM")
    }

    func testContactInitials_SingleWord() {
        let contact = Contact(name: "Alice", email: "alice@example.com")
        // Should use first two characters
        XCTAssertEqual(contact.initials, "AL")
    }

    func testContactInitials_SingleChar() {
        let contact = Contact(name: "A", email: "a@example.com")
        XCTAssertEqual(contact.initials, "A")
    }

    func testContactInitials_LowercaseIsUppercased() {
        let contact = Contact(name: "jane doe", email: "jane@example.com")
        XCTAssertEqual(contact.initials, "JD")
    }

    func testContactDomain() {
        let contact = Contact(name: "Alice", email: "alice@example.com")
        XCTAssertEqual(contact.domain, "example.com")
    }

    func testContactDomainMissing() {
        let contact = Contact(name: "Alice", email: "no-at-sign")
        XCTAssertNil(contact.domain)
    }

    func testContactDomainLowercased() {
        let contact = Contact(name: "Alice", email: "alice@EXAMPLE.COM")
        XCTAssertEqual(contact.domain, "example.com")
    }

    // MARK: - Email Init

    func testEmailPreviewFallsBackToBody() {
        let email = Email(
            sender: Contact(name: "Test", email: "test@example.com"),
            subject: "Test Subject",
            body: "This is the full body of the email that should be used as preview when none is provided."
        )
        // preview should be first 120 chars of body when no explicit preview
        XCTAssertEqual(email.preview, String(email.body.prefix(120)))
    }

    func testEmailPreviewUsedWhenProvided() {
        let email = Email(
            sender: Contact(name: "Test", email: "test@example.com"),
            subject: "Test Subject",
            body: "Full body text here",
            preview: "Custom preview"
        )
        XCTAssertEqual(email.preview, "Custom preview")
    }

    func testEmailDefaultValues() {
        let email = Email(
            sender: Contact(name: "Test", email: "test@example.com"),
            subject: "Test"
        , body: "Body")

        XCTAssertFalse(email.isRead)
        XCTAssertFalse(email.isStarred)
        XCTAssertFalse(email.hasAttachments)
        XCTAssertTrue(email.attachments.isEmpty)
        XCTAssertEqual(email.folder, .inbox)
        XCTAssertTrue(email.labels.isEmpty)
        XCTAssertFalse(email.isDraft)
        XCTAssertFalse(email.isGmailDraft)
        XCTAssertNil(email.gmailDraftID)
        XCTAssertNil(email.gmailMessageID)
        XCTAssertNil(email.gmailThreadID)
        XCTAssertTrue(email.gmailLabelIDs.isEmpty)
        XCTAssertFalse(email.isFromMailingList)
        XCTAssertNil(email.unsubscribeURL)
    }

    // MARK: - Email Equatable

    func testEmailEquatable_SameID() {
        let id = UUID()
        let email1 = Email(
            id: id,
            sender: Contact(name: "A", email: "a@a.com"),
            subject: "S1",
            body: "B1",
            isRead: false,
            isStarred: false
        )
        let email2 = Email(
            id: id,
            sender: Contact(name: "B", email: "b@b.com"),
            subject: "S2",
            body: "B2",
            isRead: false,
            isStarred: false
        )
        // Equatable only checks id, isRead, isStarred, gmailLabelIDs
        XCTAssertEqual(email1, email2)
    }

    func testEmailEquatable_DifferentReadState() {
        let id = UUID()
        let email1 = Email(
            id: id,
            sender: Contact(name: "A", email: "a@a.com"),
            subject: "S",
            body: "B",
            isRead: false
        )
        let email2 = Email(
            id: id,
            sender: Contact(name: "A", email: "a@a.com"),
            subject: "S",
            body: "B",
            isRead: true
        )
        XCTAssertNotEqual(email1, email2)
    }

    func testEmailEquatable_DifferentStarredState() {
        let id = UUID()
        let email1 = Email(
            id: id,
            sender: Contact(name: "A", email: "a@a.com"),
            subject: "S",
            body: "B",
            isStarred: false
        )
        let email2 = Email(
            id: id,
            sender: Contact(name: "A", email: "a@a.com"),
            subject: "S",
            body: "B",
            isStarred: true
        )
        XCTAssertNotEqual(email1, email2)
    }

    func testEmailEquatable_DifferentGmailLabelIDs() {
        let id = UUID()
        let email1 = Email(
            id: id,
            sender: Contact(name: "A", email: "a@a.com"),
            subject: "S",
            body: "B",
            gmailLabelIDs: ["INBOX"]
        )
        let email2 = Email(
            id: id,
            sender: Contact(name: "A", email: "a@a.com"),
            subject: "S",
            body: "B",
            gmailLabelIDs: ["INBOX", "STARRED"]
        )
        XCTAssertNotEqual(email1, email2)
    }

    // MARK: - Attachment.FileType

    func testFileTypeFromExtension_PDF() {
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "pdf"), .pdf)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "PDF"), .pdf)
    }

    func testFileTypeFromExtension_Images() {
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "jpg"), .image)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "jpeg"), .image)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "png"), .image)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "gif"), .image)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "webp"), .image)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "heic"), .image)
    }

    func testFileTypeFromExtension_Spreadsheets() {
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "xls"), .spreadsheet)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "xlsx"), .spreadsheet)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "csv"), .spreadsheet)
    }

    func testFileTypeFromExtension_Archives() {
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "zip"), .archive)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "gz"), .archive)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "tar"), .archive)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "rar"), .archive)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "7z"), .archive)
    }

    func testFileTypeFromExtension_Presentations() {
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "ppt"), .presentation)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "pptx"), .presentation)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "key"), .presentation)
    }

    func testFileTypeFromExtension_Code() {
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "swift"), .code)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "py"), .code)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "js"), .code)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "html"), .code)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "json"), .code)
    }

    func testFileTypeFromExtension_Unknown() {
        XCTAssertEqual(Attachment.FileType.from(fileExtension: "xyz"), .document)
        XCTAssertEqual(Attachment.FileType.from(fileExtension: ""), .document)
    }

    func testFileTypeLabel() {
        XCTAssertEqual(Attachment.FileType.document.label, "Document")
        XCTAssertEqual(Attachment.FileType.pdf.label, "PDF")
        XCTAssertEqual(Attachment.FileType.image.label, "Image")
        XCTAssertEqual(Attachment.FileType.spreadsheet.label, "Spreadsheet")
        XCTAssertEqual(Attachment.FileType.archive.label, "Archive")
        XCTAssertEqual(Attachment.FileType.presentation.label, "Presentation")
        XCTAssertEqual(Attachment.FileType.code.label, "Code")
    }

    // MARK: - Folder

    func testFolderGmailLabelID() {
        XCTAssertEqual(Folder.inbox.gmailLabelID, "INBOX")
        XCTAssertEqual(Folder.starred.gmailLabelID, "STARRED")
        XCTAssertEqual(Folder.sent.gmailLabelID, "SENT")
        XCTAssertEqual(Folder.drafts.gmailLabelID, "DRAFT")
        XCTAssertEqual(Folder.spam.gmailLabelID, "SPAM")
        XCTAssertEqual(Folder.trash.gmailLabelID, "TRASH")
        XCTAssertNil(Folder.archive.gmailLabelID)
        XCTAssertNil(Folder.attachments.gmailLabelID)
        XCTAssertNil(Folder.subscriptions.gmailLabelID)
        XCTAssertNil(Folder.labels.gmailLabelID)
    }

    func testFolderGmailQuery() {
        XCTAssertNotNil(Folder.archive.gmailQuery)
        XCTAssertNotNil(Folder.attachments.gmailQuery)
        XCTAssertNil(Folder.inbox.gmailQuery)
        XCTAssertNil(Folder.subscriptions.gmailQuery)
    }

    func testFolderIcon() {
        // Ensure every folder has a non-empty icon
        for folder in Folder.allCases {
            XCTAssertFalse(folder.icon.isEmpty, "\(folder) should have an icon")
        }
    }

    // MARK: - InboxCategory

    func testInboxCategoryDisplayNames() {
        XCTAssertEqual(InboxCategory.all.displayName, "All")
        XCTAssertEqual(InboxCategory.primary.displayName, "Primary")
        XCTAssertEqual(InboxCategory.social.displayName, "Social")
        XCTAssertEqual(InboxCategory.promotions.displayName, "Promotions")
        XCTAssertEqual(InboxCategory.updates.displayName, "Updates")
        XCTAssertEqual(InboxCategory.forums.displayName, "Forums")
    }

    func testInboxCategoryGmailLabelIDs() {
        XCTAssertEqual(InboxCategory.all.gmailLabelIDs, ["INBOX"])
        XCTAssertEqual(InboxCategory.primary.gmailLabelIDs, ["INBOX", "CATEGORY_PERSONAL"])
        XCTAssertEqual(InboxCategory.social.gmailLabelIDs, ["INBOX", "CATEGORY_SOCIAL"])
    }

    func testInboxCategoryIcons() {
        for category in InboxCategory.allCases {
            XCTAssertFalse(category.icon.isEmpty, "\(category) should have an icon")
        }
    }
}
