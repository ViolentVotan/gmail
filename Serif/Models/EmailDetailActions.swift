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
    var onUnsubscribe: ((URL, Bool, String?) async -> Bool)?
    var onOpenLink: ((URL) -> Void)?
    var onMessagesRead: (([String]) -> Void)?
    var onLoadDraft: ((String, String) async throws -> GmailDraft?)?

    // MARK: - Queries

    var checkUnsubscribed: ((String) -> Bool)?
    var extractBodyUnsubscribeURL: ((String) -> URL?)?
}

// MARK: - Factory

extension EmailDetailActions {
    /// Builds content-level actions shared between main detail and preview panels.
    @MainActor static func contentActions(
        panelCoordinator: PanelCoordinator,
        accountID: String
    ) -> EmailDetailActions {
        var actions = EmailDetailActions()
        actions.onPreviewAttachment = { data, name, fileType in
            panelCoordinator.previewAttachment(data: data, name: name, fileType: fileType)
        }
        actions.onShowOriginal = { msg, acctID in
            panelCoordinator.showOriginalMessage(message: msg, accountID: acctID)
        }
        actions.onDownloadMessage = { msg, acctID in
            panelCoordinator.downloadMessage(message: msg, accountID: acctID)
        }
        actions.onOpenLink = { url in panelCoordinator.openInAppBrowser(url: url) }
        actions.onUnsubscribe = { url, oneClick, msgID in
            await UnsubscribeService.shared.unsubscribe(url: url, oneClick: oneClick, messageID: msgID, accountID: accountID)
        }
        actions.checkUnsubscribed = { msgID in
            UnsubscribeService.shared.isUnsubscribed(messageID: msgID, accountID: accountID)
        }
        actions.extractBodyUnsubscribeURL = { html in
            UnsubscribeService.extractBodyUnsubscribeURL(from: html)
        }
        actions.onLoadDraft = { draftID, acctID in
            try await GmailDraftService.shared.getDraft(id: draftID, accountID: acctID, format: "full")
        }
        return actions
    }
}
