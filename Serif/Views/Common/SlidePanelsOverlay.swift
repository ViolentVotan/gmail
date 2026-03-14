import SwiftUI

struct SlidePanelsOverlay: View {
    @Bindable var panels: PanelCoordinator

    var authViewModel: AuthViewModel
    @Binding var selectedAccountID: String?
    var attachmentStore: AttachmentStore
    var mailStore: MailStore
    var mailDatabase: MailDatabase?

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

    private var emailPreviewPanel: some View {
        SlidePanel(isPresented: $panels.showEmailPreview, title: panels.previewEmail?.subject ?? "Email", scrollable: false) {
            if let email = panels.previewEmail {
                EmailDetailView(
                    email: email,
                    accountID: panels.previewAccountID,
                    mailStore: mailStore,
                    actions: buildPreviewActions(for: email),
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

        var actions = EmailDetailActions()

        // Content
        actions.onPreviewAttachment = { data, name, fileType in
            panels.previewAttachment(data: data, name: name, fileType: fileType)
        }
        actions.onShowOriginal = { msg, acctID in
            panels.showOriginalMessage(message: msg, accountID: acctID)
        }
        actions.onDownloadMessage = { msg, acctID in
            panels.downloadMessage(message: msg, accountID: acctID)
        }
        actions.onOpenLink = { url in
            panels.openInAppBrowser(url: url)
        }
        actions.onPrint = { msg, email in
            EmailPrintService.shared.printEmail(message: msg, email: email)
        }

        // Email mutations (direct service calls — no undo support in preview)
        actions.onToggleStar = { isCurrentlyStarred in
            guard let msgID = email.gmailMessageID else { return }
            Task { try? await GmailMessageService.shared.setStarred(!isCurrentlyStarred, id: msgID, accountID: accountID) }
        }
        actions.onMarkUnread = {
            guard let msgID = email.gmailMessageID else { return }
            Task { try? await GmailMessageService.shared.markAsUnread(id: msgID, accountID: accountID) }
        }

        // Unsubscribe
        actions.onUnsubscribe = { url, oneClick, msgID in
            await UnsubscribeService.shared.unsubscribe(url: url, oneClick: oneClick, messageID: msgID, accountID: accountID)
        }
        actions.checkUnsubscribed = { msgID in
            UnsubscribeService.shared.isUnsubscribed(messageID: msgID, accountID: accountID)
        }
        actions.extractBodyUnsubscribeURL = { html in
            UnsubscribeService.extractBodyUnsubscribeURL(from: html)
        }

        // Draft loading
        actions.onLoadDraft = { draftID, acctID in
            try await GmailDraftService.shared.getDraft(id: draftID, accountID: acctID, format: "full")
        }

        return actions
    }

    // MARK: - Web Browser

    private var webBrowserOverlay: some View {
        Group {
            if panels.showWebBrowser, let url = panels.webBrowserURL {
                InAppBrowserView(url: url) {
                    withAnimation(SerifAnimation.springSnappy) {
                        panels.showWebBrowser = false
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .zIndex(20)
        .animation(SerifAnimation.springSnappy, value: panels.showWebBrowser)
    }

    private func saveAttachment(data: Data, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}
