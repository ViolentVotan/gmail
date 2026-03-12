import Testing
import Foundation
@testable import Serif

@Suite struct EmailModelTests {

    // MARK: - Contact

    @Test func contactInitials_TwoWords() {
        let contact = Contact(name: "Alice Smith", email: "alice@example.com")
        #expect(contact.initials == "AS")
    }

    @Test func contactInitials_ThreeWords() {
        let contact = Contact(name: "John Michael Doe", email: "jmd@example.com")
        // Should use first letter of first two words
        #expect(contact.initials == "JM")
    }

    @Test func contactInitials_SingleWord() {
        let contact = Contact(name: "Alice", email: "alice@example.com")
        // Should use first two characters
        #expect(contact.initials == "AL")
    }

    @Test func contactInitials_SingleChar() {
        let contact = Contact(name: "A", email: "a@example.com")
        #expect(contact.initials == "A")
    }

    @Test func contactInitials_LowercaseIsUppercased() {
        let contact = Contact(name: "jane doe", email: "jane@example.com")
        #expect(contact.initials == "JD")
    }

    @Test func contactDomain() {
        let contact = Contact(name: "Alice", email: "alice@example.com")
        #expect(contact.domain == "example.com")
    }

    @Test func contactDomainMissing() {
        let contact = Contact(name: "Alice", email: "no-at-sign")
        #expect(contact.domain == nil)
    }

    @Test func contactDomainLowercased() {
        let contact = Contact(name: "Alice", email: "alice@EXAMPLE.COM")
        #expect(contact.domain == "example.com")
    }

    // MARK: - Email Init

    @Test func emailPreviewFallsBackToBody() {
        let email = Email(
            sender: Contact(name: "Test", email: "test@example.com"),
            subject: "Test Subject",
            body: "This is the full body of the email that should be used as preview when none is provided."
        )
        // preview should be first 120 chars of body when no explicit preview
        #expect(email.preview == String(email.body.prefix(120)))
    }

    @Test func emailPreviewUsedWhenProvided() {
        let email = Email(
            sender: Contact(name: "Test", email: "test@example.com"),
            subject: "Test Subject",
            body: "Full body text here",
            preview: "Custom preview"
        )
        #expect(email.preview == "Custom preview")
    }

    @Test func emailDefaultValues() {
        let email = Email(
            sender: Contact(name: "Test", email: "test@example.com"),
            subject: "Test"
        , body: "Body")

        #expect(!email.isRead)
        #expect(!email.isStarred)
        #expect(!email.hasAttachments)
        #expect(email.attachments.isEmpty)
        #expect(email.folder == .inbox)
        #expect(email.labels.isEmpty)
        #expect(!email.isDraft)
        #expect(!email.isGmailDraft)
        #expect(email.gmailDraftID == nil)
        #expect(email.gmailMessageID == nil)
        #expect(email.gmailThreadID == nil)
        #expect(email.gmailLabelIDs.isEmpty)
        #expect(!email.isFromMailingList)
        #expect(email.unsubscribeURL == nil)
    }

    // MARK: - Email Equatable

    @Test func emailEquatable_AllFieldsMatch() {
        let id = UUID()
        let sender = Contact(name: "A", email: "a@a.com")
        let date = Date()
        let email1 = Email(
            id: id,
            sender: sender,
            subject: "S",
            body: "B",
            date: date,
            isRead: false,
            isStarred: false
        )
        let email2 = Email(
            id: id,
            sender: sender,
            subject: "S",
            body: "B",
            date: date,
            isRead: false,
            isStarred: false
        )
        #expect(email1 == email2)
    }

    @Test func emailEquatable_DifferentSubject() {
        let id = UUID()
        let sender = Contact(name: "A", email: "a@a.com")
        let email1 = Email(id: id, sender: sender, subject: "S1", body: "B")
        let email2 = Email(id: id, sender: sender, subject: "S2", body: "B")
        // Synthesized Equatable checks all fields
        #expect(email1 != email2)
    }

    @Test func emailEquatable_DifferentReadState() {
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
        #expect(email1 != email2)
    }

    @Test func emailEquatable_DifferentStarredState() {
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
        #expect(email1 != email2)
    }

    @Test func emailEquatable_DifferentGmailLabelIDs() {
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
        #expect(email1 != email2)
    }

    // MARK: - Attachment.FileType

    @Test func fileTypeFromExtension_PDF() {
        #expect(Attachment.FileType.from(fileExtension: "pdf") == .pdf)
        #expect(Attachment.FileType.from(fileExtension: "PDF") == .pdf)
    }

    @Test(arguments: ["jpg", "jpeg", "png", "gif", "webp", "heic"])
    func fileTypeFromExtension_Images(ext: String) {
        #expect(Attachment.FileType.from(fileExtension: ext) == .image)
    }

    @Test(arguments: ["xls", "xlsx", "csv"])
    func fileTypeFromExtension_Spreadsheets(ext: String) {
        #expect(Attachment.FileType.from(fileExtension: ext) == .spreadsheet)
    }

    @Test(arguments: ["zip", "gz", "tar", "rar", "7z"])
    func fileTypeFromExtension_Archives(ext: String) {
        #expect(Attachment.FileType.from(fileExtension: ext) == .archive)
    }

    @Test(arguments: ["ppt", "pptx", "key"])
    func fileTypeFromExtension_Presentations(ext: String) {
        #expect(Attachment.FileType.from(fileExtension: ext) == .presentation)
    }

    @Test(arguments: ["swift", "py", "js", "html", "json"])
    func fileTypeFromExtension_Code(ext: String) {
        #expect(Attachment.FileType.from(fileExtension: ext) == .code)
    }

    @Test func fileTypeFromExtension_Unknown() {
        #expect(Attachment.FileType.from(fileExtension: "xyz") == .document)
        #expect(Attachment.FileType.from(fileExtension: "") == .document)
    }

    @Test func fileTypeLabel() {
        #expect(Attachment.FileType.document.label == "Document")
        #expect(Attachment.FileType.pdf.label == "PDF")
        #expect(Attachment.FileType.image.label == "Image")
        #expect(Attachment.FileType.spreadsheet.label == "Spreadsheet")
        #expect(Attachment.FileType.archive.label == "Archive")
        #expect(Attachment.FileType.presentation.label == "Presentation")
        #expect(Attachment.FileType.code.label == "Code")
    }

    // MARK: - Folder

    @Test func folderGmailLabelID() {
        #expect(Folder.inbox.gmailLabelID == "INBOX")
        #expect(Folder.starred.gmailLabelID == "STARRED")
        #expect(Folder.sent.gmailLabelID == "SENT")
        #expect(Folder.drafts.gmailLabelID == "DRAFT")
        #expect(Folder.spam.gmailLabelID == "SPAM")
        #expect(Folder.trash.gmailLabelID == "TRASH")
        #expect(Folder.archive.gmailLabelID == nil)
        #expect(Folder.attachments.gmailLabelID == nil)
        #expect(Folder.subscriptions.gmailLabelID == nil)
        #expect(Folder.labels.gmailLabelID == nil)
    }

    @Test func folderGmailQuery() {
        #expect(Folder.archive.gmailQuery != nil)
        #expect(Folder.attachments.gmailQuery != nil)
        #expect(Folder.inbox.gmailQuery == nil)
        #expect(Folder.subscriptions.gmailQuery == nil)
    }

    @Test func folderIcon() {
        // Ensure every folder has a non-empty icon
        for folder in Folder.allCases {
            #expect(!folder.icon.isEmpty, "\(folder) should have an icon")
        }
    }

    // MARK: - InboxCategory

    @Test func inboxCategoryDisplayNames() {
        #expect(InboxCategory.all.displayName == "All")
        #expect(InboxCategory.primary.displayName == "Primary")
        #expect(InboxCategory.social.displayName == "Social")
        #expect(InboxCategory.promotions.displayName == "Promotions")
        #expect(InboxCategory.updates.displayName == "Updates")
        #expect(InboxCategory.forums.displayName == "Forums")
    }

    @Test func inboxCategoryGmailLabelIDs() {
        #expect(InboxCategory.all.gmailLabelIDs == ["INBOX"])
        #expect(InboxCategory.primary.gmailLabelIDs == ["INBOX", "CATEGORY_PERSONAL"])
        #expect(InboxCategory.social.gmailLabelIDs == ["INBOX", "CATEGORY_SOCIAL"])
    }

    @Test func inboxCategoryIcons() {
        for category in InboxCategory.allCases {
            #expect(!category.icon.isEmpty, "\(category) should have an icon")
        }
    }
}
