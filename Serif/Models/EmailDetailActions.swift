import Foundation

struct EmailDetailActions {
    // MARK: - Email mutations

    var onArchive: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMoveToInbox: (() -> Void)?
    var onDeletePermanently: (() -> Void)?
    var onMarkNotSpam: (() -> Void)?
    var onMarkUnread: (() -> Void)?
    var onToggleStar: ((Bool) -> Void)?
    var onSnooze: ((Date) -> Void)?

    // MARK: - Compose

    var onReply: ((ComposeMode) -> Void)?
    var onReplyAll: ((ComposeMode) -> Void)?
    var onForward: ((ComposeMode) -> Void)?

    // MARK: - Labels

    var onAddLabel: ((String) -> Void)?
    var onRemoveLabel: ((String) -> Void)?
    var onCreateAndAddLabel: ((String, @escaping (String?) -> Void) -> Void)?

    // MARK: - Content

    var onPreviewAttachment: ((Data?, String, Attachment.FileType) -> Void)?
    var onShowOriginal: ((GmailMessage, String) -> Void)?   // (message, accountID)
    var onDownloadMessage: ((GmailMessage, String) -> Void)? // (message, accountID)
    var onPrint: ((GmailMessage, Email) -> Void)?
    var onUnsubscribe: ((URL, Bool, String?) async -> Bool)?
    var onOpenLink: ((URL) -> Void)?
    var onMessagesRead: (([String]) -> Void)?
    var onLoadDraft: ((String, String) async throws -> GmailDraft?)?

    // MARK: - Queries

    var checkUnsubscribed: ((String) -> Bool)?
    var extractBodyUnsubscribeURL: ((String) -> URL?)?
}
