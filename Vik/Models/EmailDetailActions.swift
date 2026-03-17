import Foundation

@MainActor
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
    /// Service-dependent closures (`onUnsubscribe`, `checkUnsubscribed`,
    /// `extractBodyUnsubscribeURL`, `onLoadDraft`) are injected by the caller so
    /// this model layer stays free of service dependencies.
    @MainActor static func contentActions(
        panelCoordinator: PanelCoordinator,
        onUnsubscribe: ((URL, Bool, String?) async -> Bool)? = nil,
        checkUnsubscribed: ((String) -> Bool)? = nil,
        extractBodyUnsubscribeURL: ((String) -> URL?)? = nil,
        onLoadDraft: ((String, String) async throws -> GmailDraft?)? = nil
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
        actions.onUnsubscribe = onUnsubscribe
        actions.checkUnsubscribed = checkUnsubscribed
        actions.extractBodyUnsubscribeURL = extractBodyUnsubscribeURL
        actions.onLoadDraft = onLoadDraft
        return actions
    }
}
