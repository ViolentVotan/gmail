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

    @ObservationIgnored private var originalMessageTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    isolated deinit {
        originalMessageTask?.cancel()
        downloadTask?.cancel()
    }

    var isAnyOpen: Bool {
        showHelp || showDebug || showAttachmentPreview || showOriginal || showWebBrowser || showEmailPreview
    }

    func closeAll() {
        originalMessageTask?.cancel()
        originalMessageTask = nil
        downloadTask?.cancel()
        downloadTask = nil
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
            withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springDefault) {
                showAttachmentPreview = true
            }
        }
    }

    func showOriginalMessage(
        message msg: GmailMessage,
        accountID: String,
        fetchRaw: @escaping @Sendable (_ id: String, _ accountID: String) async throws -> GmailMessage = { id, accountID in
            try await GmailMessageService.shared.getRawMessage(id: id, accountID: accountID)
        }
    ) {
        originalMessage = msg
        originalRawSource = nil
        isLoadingOriginal = true
        withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springDefault) {
            showOriginal = true
        }
        originalMessageTask?.cancel()
        originalMessageTask = Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await fetchRaw(msg.id, accountID)
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
        withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springDefault) {
            showEmailPreview = true
        }
    }

    func openInAppBrowser(url: URL) {
        // Only load http/https in the in-app browser; pass other schemes
        // (mailto:, tel:, maps:, etc.) to the system handler.
        guard url.scheme == "http" || url.scheme == "https" else {
            NSWorkspace.shared.open(url)
            return
        }
        webBrowserURL = url
        withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springSnappy) {
            showWebBrowser = true
        }
    }

    func downloadMessage(
        message msg: GmailMessage,
        accountID: String,
        fetchRaw: @escaping @Sendable (_ id: String, _ accountID: String) async throws -> GmailMessage = { id, accountID in
            try await GmailMessageService.shared.getRawMessage(id: id, accountID: accountID)
        }
    ) {
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await fetchRaw(msg.id, accountID)
                if let source = raw.rawSource, let data = source.data(using: .utf8) {
                    FileUtils.saveWithPanel(data: data, suggestedName: "\(msg.subject).eml")
                }
            } catch {
                ToastManager.shared.show(message: "Download failed: \(error.localizedDescription)", type: .error)
            }
        }
    }
}
