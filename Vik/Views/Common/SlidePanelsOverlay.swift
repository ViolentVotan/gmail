import SwiftUI

struct SlidePanelsOverlay: View {
    @Bindable var panels: PanelCoordinator

    var authViewModel: AuthViewModel
    @Binding var selectedAccountID: String?
    var attachmentStore: AttachmentStore
    var mailStore: MailStore
    var mailDatabase: MailDatabase?
    var attachmentIndexer: AttachmentIndexer?

    /// Closure to toggle star on a message by Gmail ID.
    /// Parameters: (gmailMessageID, isCurrentlyStarred, accountID)
    var onToggleStar: ((String, Bool, String) -> Void)?
    /// Closure to mark a message as unread by Gmail ID.
    /// Parameters: (gmailMessageID, accountID)
    var onMarkUnread: ((String, String) -> Void)?
    /// Closure to propagate read state to local DB.
    /// Parameters: (messageIDs)
    var onMessagesRead: (([String]) -> Void)?

    var body: some View {
        helpPanel
        debugPanel
        originalPanel
        attachmentPanel
        emailPreviewPanel
        webBrowserOverlay
    }

    // MARK: - Help

    private var helpPanel: some View {
        SlidePanel(isPresented: $panels.showHelp, title: "Keyboard Shortcuts") {
            ShortcutsHelpView()
        }
        .zIndex(10)
    }

    // MARK: - Debug

    private var debugPanel: some View {
        SlidePanel(isPresented: $panels.showDebug, title: "Debug") {
            DebugMenuView(accountID: selectedAccountID ?? authViewModel.primaryAccount?.id ?? "")
        }
        .zIndex(10)
    }

    // MARK: - Original Message

    private var originalPanel: some View {
        SlidePanel(isPresented: $panels.showOriginal, title: "Original Message") {
            if let msg = panels.originalMessage {
                OriginalMessageView(
                    message: msg,
                    rawSource: panels.originalRawSource,
                    isLoading: panels.isLoadingOriginal
                )
            } else {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .zIndex(10)
    }

    // MARK: - Attachment Preview

    private var attachmentPanel: some View {
        SlidePanel(isPresented: $panels.showAttachmentPreview, title: panels.attachmentPreviewName, scrollable: false) {
            if let data = panels.attachmentPreviewData {
                AttachmentPreviewView(
                    data: data,
                    fileName: panels.attachmentPreviewName,
                    fileType: panels.attachmentPreviewFileType,
                    onDownload: { saveAttachment(data: data, name: panels.attachmentPreviewName) },
                    onClose: { panels.showAttachmentPreview = false }
                )
            } else {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .zIndex(10)
    }

    // MARK: - Email Preview

    /// Cache holder for preview actions — class reference avoids state mutation during body evaluation.
    private final class PreviewActionsCache {
        var actions: EmailDetailActions?
        var emailID: UUID?
    }

    @State private var previewActionsCache = PreviewActionsCache()

    private func cachedPreviewActions(for email: Email) -> EmailDetailActions {
        let cache = previewActionsCache
        if cache.emailID == email.id, let cached = cache.actions {
            return cached
        }
        let built = buildPreviewActions(for: email)
        cache.actions = built
        cache.emailID = email.id
        return built
    }

    private var emailPreviewPanel: some View {
        SlidePanel(isPresented: $panels.showEmailPreview, title: panels.previewEmail?.subject ?? "Email", scrollable: false) {
            if let email = panels.previewEmail {
                EmailDetailView(
                    email: email,
                    accountID: panels.previewAccountID,
                    mailStore: mailStore,
                    actions: cachedPreviewActions(for: email),
                    attachmentIndexer: attachmentIndexer,
                    mailDatabase: mailDatabase
                )
            }
        }
        .zIndex(10)
    }

    /// Builds actions for the email preview panel, wiring everything
    /// that can work without a full AppCoordinator/MailboxViewModel.
    private func buildPreviewActions(for email: Email) -> EmailDetailActions {
        let accountID = panels.previewAccountID

        var actions = EmailDetailActions.contentActions(
            panelCoordinator: panels
        )

        // Email mutations — routed through closures from parent (no direct service calls)
        actions.onToggleStar = { isCurrentlyStarred in
            guard let msgID = email.gmailMessageID else { return }
            onToggleStar?(msgID, isCurrentlyStarred, accountID)
        }
        actions.onMarkUnread = {
            guard let msgID = email.gmailMessageID else { return }
            onMarkUnread?(msgID, accountID)
        }

        actions.onMessagesRead = { messageIDs in
            onMessagesRead?(messageIDs)
        }

        return actions
    }

    // MARK: - Web Browser

    private var webBrowserOverlay: some View {
        Group {
            if panels.showWebBrowser, let url = panels.webBrowserURL {
                InAppBrowserView(url: url) {
                    withAnimation(VikAnimation.springSnappy) {
                        panels.showWebBrowser = false
                    }
                }
                .onKeyPress(.escape) { panels.showWebBrowser = false; return .handled }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .zIndex(20)
        .animation(VikAnimation.springSnappy, value: panels.showWebBrowser)
    }

    private func saveAttachment(data: Data, name: String) {
        FileUtils.saveWithPanel(data: data, suggestedName: name)
    }
}
