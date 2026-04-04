import SwiftUI

/// Encapsulates the reply-bar lifecycle: draft loading, auto-save scheduling,
/// collapsed placeholder text, send/schedule from bar, and file-drop routing.
///
/// Owned by ``ComposeViewModel`` as an optional `replyBar` property — created
/// when the compose flow enters inline-reply mode (i.e. ``ReplyBarView``).
@Observable
@MainActor
final class ReplyBarViewModel {

    // MARK: - Reply Bar UI State

    var sendError: String?
    var subjectOverride: String?
    var isLoadingDraft = false
    var isInitialLoad = true
    private(set) var collapsedPlaceholderText = "Write a reply..."

    // MARK: - Private State

    @ObservationIgnored private var cachedStrippedText = ""
    @ObservationIgnored private var lastDraftSaveDate: Date = .distantPast
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadDraftTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var stripTask: Task<Void, Never>?

    static let autoSaveGuardDelay: Duration = .seconds(0.5)
    private static let minSaveInterval: TimeInterval = 10

    // MARK: - Parent Reference

    /// The owning compose view model — provides shared compose fields and send/draft APIs.
    let compose: ComposeViewModel

    init(compose: ComposeViewModel) {
        self.compose = compose
    }

    isolated deinit {
        saveTask?.cancel()
        loadDraftTask?.cancel()
        stripTask?.cancel()
    }

    // MARK: - Computed

    var replyBodyIsEmpty: Bool {
        cachedStrippedText.isEmpty
    }

    var hasUserContent: Bool {
        !replyBodyIsEmpty || !compose.attachments.isEmpty ||
        !compose.cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !compose.bcc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hasSavedDraft(for email: Email, in mailStore: MailStore) -> Bool {
        guard let threadID = email.gmailThreadID else { return false }
        return mailStore.replyDrafts[threadID] != nil
    }

    func updateCollapsedPlaceholder(for email: Email, in mailStore: MailStore) {
        if !cachedStrippedText.isEmpty {
            let preview = String(cachedStrippedText.prefix(50))
            let ellipsis = cachedStrippedText.count > 50 ? "\u{2026}" : ""
            if !compose.to.isEmpty {
                let recipientCount = compose.splitAddresses(compose.to).count + compose.splitAddresses(compose.cc).count
                if recipientCount > 1 {
                    collapsedPlaceholderText = "Reply All (\(recipientCount)) \u{00B7} \(preview)\(ellipsis)"
                } else {
                    let recipient = compose.splitAddresses(compose.to).first ?? ""
                    collapsedPlaceholderText = "Reply to \(recipient) \u{00B7} \(preview)\(ellipsis)"
                }
            } else {
                collapsedPlaceholderText = "\(preview)\(ellipsis)"
            }
            return
        }
        if let threadID = email.gmailThreadID,
           let saved = mailStore.replyDrafts[threadID] {
            let preview = saved.preview
            let ellipsis = preview.count >= 50 ? "\u{2026}" : ""
            collapsedPlaceholderText = "Draft: \(preview)\(ellipsis)"
            return
        }
        let senderName = email.sender.name.isEmpty ? email.sender.email : email.sender.name
        collapsedPlaceholderText = "Reply to \(senderName)\u{2026}"
    }

    // MARK: - Content Tracking

    @concurrent private static func stripHTML(_ html: String) async -> String {
        html.strippingHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateCachedText(html: String) {
        stripTask?.cancel()
        stripTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let stripped = await Self.stripHTML(html)
            guard !Task.isCancelled else { return }
            cachedStrippedText = stripped
        }
    }

    // MARK: - Lifecycle

    /// Resets all reply-bar state for a new email.
    func resetForEmail(_ email: Email) {
        saveTask?.cancel()
        saveTask = nil
        loadDraftTask?.cancel()
        loadDraftTask = nil
        stripTask?.cancel()
        stripTask = nil
        loadGeneration += 1

        compose.to = ""
        compose.cc = ""
        compose.bcc = ""
        compose.body = ""
        compose.attachments = []
        compose.showCc = false
        compose.showBcc = false
        sendError = nil
        subjectOverride = nil
        cachedStrippedText = ""
        collapsedPlaceholderText = "Write a reply..."
        compose.isSent = false
        compose.isSending = false
        compose.gmailDraftID = nil
        isInitialLoad = true
        isLoadingDraft = false

        compose.threadID = email.gmailThreadID
    }

    /// Collapses the reply bar, discarding local and remote draft state.
    /// Does NOT touch `isExpanded` — that is view-local `@State`.
    func collapse(email: Email, mailStore: MailStore) {
        saveTask?.cancel()
        if let threadID = email.gmailThreadID {
            mailStore.replyDrafts.removeValue(forKey: threadID)
            mailStore.saveReplyDrafts()
        }
        if compose.gmailDraftID != nil {
            Task { await compose.discardDraft() }
        }
        compose.to = ""
        compose.cc = ""
        compose.bcc = ""
        compose.body = ""
        compose.attachments = []
        compose.showCc = false
        compose.showBcc = false
        sendError = nil
        subjectOverride = nil
        cachedStrippedText = ""
        collapsedPlaceholderText = "Write a reply..."
    }

    /// Whether the user should be warned before discarding the reply bar.
    func shouldShowDiscardAlert(email: Email, mailStore: MailStore) -> Bool {
        hasSavedDraft(for: email, in: mailStore) || compose.gmailDraftID != nil
    }

    // MARK: - Draft Loading

    /// Loads an existing reply draft into the editor, guarded by `loadGeneration` for staleness.
    func loadExistingDraftForReply(
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
            let result = await compose.loadExistingDraft(
                mailStore: mailStore,
                loader: loader
            )
            guard !Task.isCancelled, currentGen == loadGeneration else { return }
            if let draftBody = result, !draftBody.isEmpty {
                isInitialLoad = true
                compose.body = draftBody
                editorState.setHTML(draftBody)
                isLoadingDraft = false
                try? await Task.sleep(for: Self.autoSaveGuardDelay)
                guard !Task.isCancelled, currentGen == loadGeneration else { return }
                isInitialLoad = false
            } else {
                isLoadingDraft = false
            }
        }
    }

    // MARK: - Send / Schedule

    /// Sends a reply from the inline reply bar.
    func sendReplyFromBar(
        email: Email,
        editorInlineImages: [InlineImageAttachment],
        mailStore: MailStore
    ) async {
        sendError = nil
        saveTask?.cancel()

        await compose.sendReplyMessage(
            replyHTML: compose.body,
            to: compose.to,
            cc: compose.cc,
            bcc: compose.bcc,
            emailSubject: subjectOverride ?? email.subject,
            replyToMessageID: email.gmailMessageID,
            parentMessageID: email.messageIDHeader,
            parentReferences: email.referencesHeader,
            fileAttachments: compose.attachments,
            editorInlineImages: editorInlineImages,
            mailStore: mailStore
        )

        if let err = compose.error {
            sendError = err
        }
    }

    /// Schedules a reply from the inline reply bar.
    func scheduleReplyFromBar(
        at date: Date,
        email: Email,
        editorInlineImages: [InlineImageAttachment],
        mailStore: MailStore
    ) async {
        sendError = nil
        saveTask?.cancel()

        let bodySnapshot = compose.body
        let (processedHTML, images) = await Task.detached {
            InlineImageProcessor.extractInlineImages(from: bodySnapshot)
        }.value

        compose.subject = (subjectOverride ?? email.subject).withReplyPrefix
        compose.body = processedHTML
        compose.isHTML = true
        compose.inlineImages = images + editorInlineImages
        compose.replyToMessageID = email.gmailMessageID
        compose.parentMessageID = email.messageIDHeader
        compose.parentReferences = email.referencesHeader

        compose.setReplyCleanupContext(mailStore: mailStore)
        await compose.scheduleSend(at: date)

        if let err = compose.error {
            sendError = err
        }
    }

    // MARK: - Auto-Save

    /// Unified auto-save with local-first persistence: writes to `mailStore.replyDrafts`
    /// immediately, then rate-limits the remote API save.
    func scheduleReplyAutoSaveUnified(email: Email, mailStore: MailStore) {
        guard !isInitialLoad, !isLoadingDraft else { return }

        let isEmpty = compose.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty {
            saveTask?.cancel()
            if let threadID = email.gmailThreadID, mailStore.replyDrafts[threadID] != nil {
                mailStore.replyDrafts.removeValue(forKey: threadID)
                mailStore.saveReplyDrafts()
                if compose.gmailDraftID != nil {
                    Task { [weak compose] in await compose?.discardDraft() }
                }
            }
            return
        }

        // Local-first: persist draft preview immediately
        if let threadID = email.gmailThreadID {
            let plain = (cachedStrippedText.isEmpty ? compose.body : cachedStrippedText).trimmingCharacters(in: .whitespacesAndNewlines)
            let draftID = compose.gmailDraftID ?? mailStore.replyDrafts[threadID]?.gmailDraftID ?? ""
            mailStore.replyDrafts[threadID] = .init(
                gmailDraftID: draftID,
                preview: String(plain.prefix(50))
            )
            mailStore.saveReplyDrafts()
        }

        // Rate-limit remote API saves
        if Date.now.timeIntervalSince(lastDraftSaveDate) < Self.minSaveInterval {
            let remaining = Self.minSaveInterval - Date.now.timeIntervalSince(lastDraftSaveDate)
            saveTask?.cancel()
            saveTask = Task { [weak compose] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, let compose else { return }
                lastDraftSaveDate = .now
                saveTask = compose.scheduleReplyAutoSave(
                    replyHTML: compose.body, to: compose.to, cc: compose.cc, bcc: compose.bcc,
                    emailSubject: subjectOverride ?? email.subject,
                    replyToMessageID: email.gmailMessageID,
                    mailStore: mailStore, previousTask: nil
                )
            }
            return
        }

        lastDraftSaveDate = .now
        saveTask = compose.scheduleReplyAutoSave(
            replyHTML: compose.body, to: compose.to, cc: compose.cc, bcc: compose.bcc,
            emailSubject: subjectOverride ?? email.subject,
            replyToMessageID: email.gmailMessageID,
            mailStore: mailStore, previousTask: saveTask
        )
    }

    // MARK: - File Helpers

    /// Routes a file drop through `handleFileDrop`, inserting images inline or appending attachments.
    func handleFileDropForReply(_ url: URL, editorState: WebRichTextEditorState) {
        switch compose.handleFileDrop(url) {
        case .image:
            editorState.insertImage(from: url)
        case .attachment:
            compose.attachments.append(url)
        case .unsupported(let message):
            compose.showToast(message, type: .error)
        }
    }

    /// Opens a file picker and appends the selected files to `attachments`.
    func attachFilesForReply() async {
        let urls = await compose.openAttachmentPicker()
        compose.attachments.append(contentsOf: urls)
    }

    /// Cancels all reply-bar background tasks.
    func cancelReplyTasks() {
        saveTask?.cancel()
        loadDraftTask?.cancel()
        stripTask?.cancel()
    }
}
