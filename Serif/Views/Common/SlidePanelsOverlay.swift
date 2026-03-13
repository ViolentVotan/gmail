import SwiftUI

struct SlidePanelsOverlay: View {
    @Bindable var panels: PanelCoordinator

    var authViewModel: AuthViewModel
    @Binding var selectedAccountID: String?
    var attachmentStore: AttachmentStore
    var mailStore: MailStore

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
                    onPreviewAttachment: { data, name, fileType in
                        panels.previewAttachment(data: data, name: name, fileType: fileType)
                    }
                )
            }
        }
        .zIndex(10)
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
