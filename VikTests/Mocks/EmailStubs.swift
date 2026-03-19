import Foundation
@testable import Vik

extension Email {
    /// Convenience factory for tests. All fields have sensible defaults.
    static func stub(
        id: UUID = UUID(),
        sender: Contact = Contact(name: "Alice Sender", email: "alice@example.com"),
        recipients: [Contact] = [Contact(name: "Bob Recipient", email: "bob@example.com")],
        cc: [Contact] = [],
        subject: String = "Test Subject",
        body: String = "Test body",
        preview: String = "Test body",
        date: Date = Date(),
        isRead: Bool = true,
        isStarred: Bool = false,
        hasAttachments: Bool = false,
        attachments: [Attachment] = [],
        folder: Folder = .inbox,
        labels: [EmailLabel] = [],
        isDraft: Bool = false,
        gmailDraftID: String? = nil,
        gmailMessageID: String? = "msg-123",
        gmailThreadID: String? = "thread-456",
        gmailLabelIDs: [String] = [],
        threadMessageCount: Int = 1,
        isFromMailingList: Bool = false,
        unsubscribeURL: URL? = nil,
        tags: EmailTags? = nil,
        messageIDHeader: String? = nil,
        referencesHeader: String? = nil
    ) -> Email {
        Email(
            id: id,
            sender: sender,
            recipients: recipients,
            cc: cc,
            subject: subject,
            body: body,
            preview: preview,
            date: date,
            isRead: isRead,
            isStarred: isStarred,
            hasAttachments: hasAttachments,
            attachments: attachments,
            folder: folder,
            labels: labels,
            isDraft: isDraft,
            gmailDraftID: gmailDraftID,
            gmailMessageID: gmailMessageID,
            gmailThreadID: gmailThreadID,
            gmailLabelIDs: gmailLabelIDs,
            threadMessageCount: threadMessageCount,
            isFromMailingList: isFromMailingList,
            unsubscribeURL: unsubscribeURL,
            tags: tags,
            messageIDHeader: messageIDHeader,
            referencesHeader: referencesHeader
        )
    }
}
