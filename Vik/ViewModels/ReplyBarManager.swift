import SwiftUI

@Observable @MainActor final class ReplyBarManager {

    // MARK: - Constants

    /// Suppresses auto-save during initial render / draft load to avoid
    /// echoing the loaded content back as a "new" draft save.
    static let autoSaveGuardDelay: Duration = .seconds(0.5)

    /// Minimum interval between actual Gmail draft API saves.
    private static let minSaveInterval: TimeInterval = 10

    // MARK: - State

    var replyHTML = ""
    var replyTo = ""
    var replyCc = ""
    var replyBcc = ""
    var showCc = false
    var showBcc = false
    var attachments: [URL] = []
    var sendError: String?
    var isLoadingDraft = false
    var isInitialLoad = true
    var isLoadingReplies = false
    var quickReplies: [String] = []
    var subjectOverride: String?
    var showSubject = false
    private(set) var composeVM: ComposeViewModel

    // MARK: - Internal

    var saveTask: Task<Void, Never>?
    var loadDraftTask: Task<Void, Never>?
    var loadGeneration = 0
    private var cachedStrippedText = ""
    private var lastDraftSaveDate: Date = .distantPast
    private var draftLoadBaseline: Date = .distantPast

    // MARK: - Identity

    let accountID: String
    let fromAddress: String

    // MARK: - Computed

    var replyBodyIsEmpty: Bool {
        cachedStrippedText.isEmpty
    }

    var hasUserContent: Bool {
        !replyBodyIsEmpty || !attachments.isEmpty ||
        !replyCc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !replyBcc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hasSavedDraft(for email: Email, in mailStore: MailStore) -> Bool {
        guard let threadID = email.gmailThreadID else { return false }
        return mailStore.replyDrafts[threadID] != nil
    }

    func collapsedPlaceholder(for email: Email, in mailStore: MailStore) -> String {
        if !cachedStrippedText.isEmpty {
            let preview = String(cachedStrippedText.prefix(50))
            return "\(preview)\(cachedStrippedText.count > 50 ? "…" : "")"
        }
        if let threadID = email.gmailThreadID,
           let saved = mailStore.replyDrafts[threadID] {
            let preview = saved.preview
            return "\(preview)\(preview.count >= 50 ? "…" : "")"
        }
        return "Write a reply..."
    }

    // MARK: - Init

    init(accountID: String, fromAddress: String, email: Email) {
        self.accountID = accountID
        self.fromAddress = fromAddress
        self.composeVM = ComposeViewModel(
            accountID: accountID,
            fromAddress: fromAddress,
            threadID: email.gmailThreadID
        )
    }

    // MARK: - Lifecycle

    func resetEmail(
        email: Email,
        onGenerateQuickReplies: ((Email) async -> [String])?
    ) async {
        saveTask?.cancel()
        saveTask = nil
        loadDraftTask?.cancel()
        loadDraftTask = nil
        loadGeneration += 1
        composeVM = ComposeViewModel(
            accountID: accountID,
            fromAddress: fromAddress,
            threadID: email.gmailThreadID
        )
        isLoadingReplies = true
        quickReplies = await onGenerateQuickReplies?(email) ?? []
        isLoadingReplies = false
    }

    // MARK: - Content Update

    func updateCachedText() {
        cachedStrippedText = replyHTML.strippingHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions

    func sendReply(
        email: Email,
        editorInlineImages: [InlineImageAttachment],
        mailStore: MailStore
    ) async {
        sendError = nil
        saveTask?.cancel()

        await composeVM.sendReplyMessage(
            replyHTML: replyHTML,
            to: replyTo,
            cc: replyCc,
            bcc: replyBcc,
            emailSubject: subjectOverride ?? email.subject,
            replyToMessageID: email.gmailMessageID,
            parentMessageID: email.messageIDHeader,
            parentReferences: email.referencesHeader,
            attachmentURLs: attachments,
            editorInlineImages: editorInlineImages,
            mailStore: mailStore
        )

        if let error = composeVM.error {
            sendError = error
        }
    }

    func scheduleReply(
        at date: Date,
        email: Email,
        editorInlineImages: [InlineImageAttachment],
        mailStore: MailStore
    ) async {
        sendError = nil
        saveTask?.cancel()

        let (processedHTML, images) = InlineImageProcessor.extractInlineImages(from: replyHTML)
        syncFieldsToComposeVM(processedHTML: processedHTML, images: images + editorInlineImages, email: email)
        composeVM.setReplyCleanupContext(mailStore: mailStore)
        await composeVM.scheduleSend(at: date)

        if let error = composeVM.error {
            sendError = error
        }
    }

    func shouldShowDiscardAlert(email: Email, mailStore: MailStore) -> Bool {
        hasSavedDraft(for: email, in: mailStore) || composeVM.gmailDraftID != nil
    }

    func collapse(email: Email, mailStore: MailStore) {
        saveTask?.cancel()
        if let threadID = email.gmailThreadID {
            mailStore.replyDrafts.removeValue(forKey: threadID)
            mailStore.saveReplyDrafts()
        }
        if composeVM.gmailDraftID != nil {
            Task { await composeVM.discardDraft() }
        }
        replyHTML = ""
        replyTo = ""
        replyCc = ""
        replyBcc = ""
        showCc = false
        showBcc = false
        attachments = []
        sendError = nil
        subjectOverride = nil
        showSubject = false
    }

    func loadExistingDraft(
        email: Email,
        mailStore: MailStore,
        loader: ((String, String) async throws -> GmailDraft?)?,
        editorState: WebRichTextEditorState
    ) {
        guard let threadID = email.gmailThreadID,
              mailStore.replyDrafts[threadID] != nil else { return }
        isLoadingDraft = true
        loadDraftTask?.cancel()
        let currentGen = loadGeneration
        loadDraftTask = Task {
            let result = await composeVM.loadExistingDraft(
                mailStore: mailStore,
                loader: loader
            )
            guard !Task.isCancelled, currentGen == loadGeneration else { return }
            if let body = result, !body.isEmpty {
                isInitialLoad = true
                replyHTML = body
                editorState.setHTML(body)
                isLoadingDraft = false
                try? await Task.sleep(for: Self.autoSaveGuardDelay)
                guard !Task.isCancelled, currentGen == loadGeneration else { return }
                isInitialLoad = false
            } else {
                isLoadingDraft = false
            }
        }
    }

    func scheduleAutoSave(email: Email, mailStore: MailStore) {
        guard !isInitialLoad, !isLoadingDraft else { return }
        saveTask = composeVM.scheduleReplyAutoSave(
            replyHTML: replyHTML,
            to: replyTo,
            cc: replyCc,
            bcc: replyBcc,
            emailSubject: subjectOverride ?? email.subject,
            replyToMessageID: email.gmailMessageID,
            mailStore: mailStore,
            previousTask: saveTask
        )
    }

    func handleFileDrop(_ url: URL, editorState: WebRichTextEditorState) {
        switch composeVM.handleFileDrop(url) {
        case .image:
            editorState.insertImage(from: url)
        case .attachment:
            attachments.append(url)
        case .unsupported(let message):
            composeVM.showToast(message, type: .error)
        }
    }

    func attachFiles() async -> [URL] {
        await composeVM.openAttachmentPicker()
    }

    func cancelTasks() {
        saveTask?.cancel()
        loadDraftTask?.cancel()
    }

    // MARK: - Helpers

    private func syncFieldsToComposeVM(processedHTML: String, images: [InlineImageAttachment], email: Email) {
        composeVM.to = replyTo
        composeVM.cc = replyCc
        composeVM.bcc = replyBcc
        composeVM.subject = (subjectOverride ?? email.subject).withReplyPrefix
        composeVM.body = processedHTML
        composeVM.isHTML = true
        composeVM.inlineImages = images
        composeVM.replyToMessageID = email.gmailMessageID
        composeVM.parentMessageID = email.messageIDHeader
        composeVM.parentReferences = email.referencesHeader
        composeVM.attachmentURLs = attachments
    }
}
