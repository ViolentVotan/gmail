import SwiftUI

@Observable
@MainActor
final class PanelCoordinator {
    // MARK: - Panel visibility

    var showHelp = false
    var showDebug = false
    var showOriginal = false
    var showAttachmentPreview = false
    var showWebBrowser = false

    // MARK: - Web browser data

    var webBrowserURL: URL?

    // MARK: - Original message data

    var originalMessage: GmailMessage?
    var originalRawSource: String?
    var isLoadingOriginal = false

    // MARK: - Email preview data

    var showEmailPreview = false
    var previewEmail: Email?
    var previewAccountID = ""

    // MARK: - Attachment preview data

    var attachmentPreviewData: Data?
    var attachmentPreviewName = ""
    var attachmentPreviewFileType: Attachment.FileType = .document

    var isAnyOpen: Bool {
        showHelp || showDebug || showAttachmentPreview || showOriginal || showWebBrowser || showEmailPreview
    }

    func closeAll() {
        showHelp = false
        showDebug = false
        showAttachmentPreview = false
        showOriginal = false
        showWebBrowser = false
        showEmailPreview = false
    }

    func previewAttachment(data: Data?, name: String, fileType: Attachment.FileType) {
        attachmentPreviewData = data
        attachmentPreviewName = name
        attachmentPreviewFileType = fileType
        if !showAttachmentPreview {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showAttachmentPreview = true
            }
        }
    }

    func showOriginalMessage(message msg: GmailMessage, accountID: String) {
        originalMessage = msg
        originalRawSource = nil
        isLoadingOriginal = true
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showOriginal = true
        }
        Task {
            do {
                let raw = try await GmailMessageService.shared.getRawMessage(id: msg.id, accountID: accountID)
                self.originalRawSource = raw.rawSource
            } catch {
                self.originalRawSource = nil
            }
            self.isLoadingOriginal = false
        }
    }

    func showEmail(_ email: Email, accountID: String) {
        previewEmail = email
        previewAccountID = accountID
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showEmailPreview = true
        }
    }

    func openInAppBrowser(url: URL) {
        webBrowserURL = url
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            showWebBrowser = true
        }
    }

    func downloadMessage(message msg: GmailMessage, accountID: String) {
        Task {
            do {
                let raw = try await GmailMessageService.shared.getRawMessage(id: msg.id, accountID: accountID)
                if let source = raw.rawSource {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "\(msg.subject).eml"
                    panel.canCreateDirectories = true
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    try? source.data(using: .utf8)?.write(to: url)
                }
            } catch {
                ToastManager.shared.show(message: "Download failed: \(error.localizedDescription)", type: .error)
            }
        }
    }
}
