import SwiftUI

/// Drives the compose / reply / draft editing flow.
@Observable
@MainActor
final class ComposeViewModel {
    var to:        String = ""
    var cc:        String = ""
    var bcc:       String = ""
    var subject:   String = ""
    var body:      String = ""
    @ObservationIgnored var isHTML = false
    @ObservationIgnored var inlineImages: [InlineImageAttachment] = []
    var isSending    = false
    var isSent       = false
    var wasScheduled = false
    var error:       String?

    @ObservationIgnored let accountID:   String
    @ObservationIgnored var fromAddress: String
    @ObservationIgnored var gmailDraftID:     String?   // set once we've created a remote draft
    @ObservationIgnored private var saveDraftTask: Task<Void, Never>?
    @ObservationIgnored var threadID:         String?   // for replies
    @ObservationIgnored var replyToMessageID: String?   // for In-Reply-To / References headers
    @ObservationIgnored var parentMessageID:  String?   // parent's RFC 2822 Message-ID (for References chain)
    @ObservationIgnored var parentReferences: String?   // parent's RFC 2822 References (for References chain)
    var attachments: [URL] = []

    // Reply draft cleanup context — set by sendReplyMessage/setReplyCleanupContext, consumed by send()/scheduleSend()
    @ObservationIgnored private(set) var replyCleanupMailStore: MailStore?
    @ObservationIgnored private var replyCleanupDraftID: String?

    // MARK: - Reply Bar State

    var showCc = false
    var showBcc = false
    var subjectOverride: String?
    var sendError: String?
    var isLoadingDraft = false
    var isInitialLoad = true

    @ObservationIgnored private var cachedStrippedText = ""
    @ObservationIgnored private var lastDraftSaveDate: Date = .distantPast
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadDraftTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var stripTask: Task<Void, Never>?

    static let autoSaveGuardDelay: Duration = .seconds(0.5)
    private static let minSaveInterval: TimeInterval = 10

    func setReplyCleanupContext(mailStore: MailStore) {
        replyCleanupMailStore = mailStore
        if gmailDraftID == nil, let threadID, let saved = mailStore.replyDrafts[threadID] {
            gmailDraftID = saved.gmailDraftID
        }
        replyCleanupDraftID = gmailDraftID
    }

    init(accountID: String, fromAddress: String, threadID: String? = nil) {
        self.accountID   = accountID
        self.fromAddress = fromAddress
        self.threadID    = threadID
    }

    isolated deinit {
        saveDraftTask?.cancel()
        saveTask?.cancel()
        loadDraftTask?.cancel()
        stripTask?.cancel()
    }

    // MARK: - Send

    var isAwaitingUndoSend = false

    func send() async {
        error = nil
        isAwaitingUndoSend = true
        isSending = true

        // Capture all send parameters by value so the closure survives if the
        // ComposeView (and thus this VM) is dismissed before the undo fires.
        let capturedFrom = fromAddress
        let capturedTo = splitAddresses(to)
        let capturedCC = splitAddresses(cc)
        let capturedBCC = splitAddresses(bcc)
        let capturedSubject = subject
        let capturedBody = body
        let capturedIsHTML = isHTML
        let capturedThreadID = threadID
        let capturedParentMessageID = parentMessageID
        let capturedParentReferences = parentReferences
        let capturedInlineImages = inlineImages
        let capturedAttachments = attachments.isEmpty ? nil : attachments
        let capturedAccountID = accountID
        let capturedDraftID = gmailDraftID
        let capturedReplyCleanupMailStore = replyCleanupMailStore
        let capturedReplyCleanupDraftID = replyCleanupDraftID

        UndoActionManager.shared.schedule(
            label: "Sending...",
            onConfirm: { [weak self] in
                Task { @MainActor in
                    self?.isAwaitingUndoSend = false
                    var sendSucceeded = false
                    do {
                        _ = try await GmailSendService.shared.send(
                            from:               capturedFrom,
                            to:                 capturedTo,
                            cc:                 capturedCC,
                            bcc:                capturedBCC,
                            subject:            capturedSubject,
                            body:               capturedBody,
                            isHTML:             capturedIsHTML,
                            threadID:           capturedThreadID,
                            inReplyTo:          capturedParentMessageID,
                            references:         GmailSendService.buildReferencesChain(
                                                    parentReferences: capturedParentReferences,
                                                    parentMessageID: capturedParentMessageID
                                                ),
                            inlineImages:       capturedInlineImages,
                            attachments:        capturedAttachments,
                            accountID:          capturedAccountID
                        )
                        if let draftID = capturedDraftID {
                            try? await GmailDraftService.shared.deleteDraft(draftID: draftID, accountID: capturedAccountID)
                        }
                        self?.isSent = true
                        sendSucceeded = true
                        SoundManager.play(.sent)
                        VikHaptic.levelChange()
                    } catch let apiError as GmailAPIError {
                        if case .offline = apiError {
                            // Offline — build the raw MIME payload and queue for later
                            do {
                                let raw = try GmailSendService.buildRawMessage(
                                    from: capturedFrom,
                                    to: capturedTo,
                                    cc: capturedCC,
                                    bcc: capturedBCC,
                                    subject: capturedSubject,
                                    body: capturedBody,
                                    isHTML: capturedIsHTML,
                                    inReplyTo: capturedParentMessageID,
                                    references: GmailSendService.buildReferencesChain(
                                        parentReferences: capturedParentReferences,
                                        parentMessageID: capturedParentMessageID
                                    ),
                                    inlineImages: capturedInlineImages,
                                    attachments: capturedAttachments ?? []
                                )
                                let action = OfflineAction(
                                    actionType: .send(rawBase64URL: raw, threadID: capturedThreadID),
                                    messageIds: [],
                                    accountID: capturedAccountID
                                )
                                await OfflineActionQueue.shared.enqueue(action)
                                self?.isSent = true
                                sendSucceeded = true
                                ToastManager.shared.show(message: "Email queued — will send when online")
                            } catch {
                                self?.error = error.localizedDescription
                            }
                        } else {
                            self?.error = apiError.localizedDescription
                        }
                    } catch {
                        self?.error = error.localizedDescription
                    }
                    // Clean up reply draft references after any successful send
                    // (online or offline-queued). Uses strongly captured values so
                    // cleanup runs even if self (ComposeViewModel) was deallocated.
                    if sendSucceeded, let store = capturedReplyCleanupMailStore {
                        if let tid = capturedThreadID {
                            store.replyDrafts.removeValue(forKey: tid)
                            store.saveReplyDrafts()
                        }
                        if let gid = capturedReplyCleanupDraftID {
                            store.gmailDrafts.removeAll { $0.gmailDraftID == gid }
                        }
                    }
                    self?.isSending = false
                }
            },
            onUndo: {
                Task { @MainActor [weak self] in
                    self?.isAwaitingUndoSend = false
                    self?.isSending = false
                }
            }
        )
    }

    func scheduleSend(at scheduledDate: Date) async {
        isSending = true
        error = nil
        defer { isSending = false }

        await saveDraft()
        guard let draftID = gmailDraftID else {
            error = "Failed to save draft for scheduling"
            return
        }

        // Capture reply draft cleanup context after saveDraft (gmailDraftID is now populated)
        let cleanupStore = replyCleanupMailStore
        let cleanupThreadID = threadID

        let item = ScheduledSendItem(
            draftId: draftID,
            accountID: accountID,
            scheduledTime: scheduledDate,
            subject: subject,
            recipients: splitAddresses(to)
        )
        ScheduledSendStore.shared.add(item)

        // Clean up reply draft registry if this was a reply
        if let store = cleanupStore, let tid = cleanupThreadID {
            store.replyDrafts.removeValue(forKey: tid)
            store.saveReplyDrafts()
            if let gid = gmailDraftID {
                store.gmailDrafts.removeAll { $0.gmailDraftID == gid }
            }
        }

        wasScheduled = true
        isSent = true
        ToastManager.shared.show(message: "Email scheduled")
    }

    // MARK: - Draft

    func saveDraft() async {
        // Cancel any previous in-flight save so we don't get double creates
        saveDraftTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            do {
                // Extract inline data: URLs → cid: + MIME parts for proper Gmail storage
                let bodySnapshot = body
                let (processedBody, extractedImages) = await Task.detached {
                    InlineImageProcessor.extractInlineImages(from: bodySnapshot)
                }.value
                let allImages = extractedImages + inlineImages

                // Build threading headers for reply drafts
                let refsChain = GmailSendService.buildReferencesChain(
                    parentReferences: parentReferences,
                    parentMessageID: parentMessageID
                )

                if let draftID = gmailDraftID {
                    let draft = try await GmailDraftService.shared.updateDraft(
                        draftID:      draftID,
                        from:         fromAddress,
                        to:           splitAddresses(to),
                        cc:           splitAddresses(cc),
                        bcc:          splitAddresses(bcc),
                        subject:      subject,
                        body:         processedBody,
                        isHTML:       isHTML,
                        inReplyTo:    parentMessageID,
                        references:   refsChain,
                        inlineImages: allImages,
                        accountID:    accountID
                    )
                    guard !Task.isCancelled else { return }
                    self.gmailDraftID = draft.id
                } else {
                    let draft = try await GmailDraftService.shared.createDraft(
                        from:         fromAddress,
                        to:           splitAddresses(to),
                        cc:           splitAddresses(cc),
                        bcc:          splitAddresses(bcc),
                        subject:      subject,
                        body:         processedBody,
                        isHTML:       isHTML,
                        inReplyTo:    parentMessageID,
                        references:   refsChain,
                        inlineImages: allImages,
                        accountID:    accountID
                    )
                    guard !Task.isCancelled else { return }
                    self.gmailDraftID = draft.id
                }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
        saveDraftTask = task
        await task.value
    }

    func discardDraft() async {
        saveDraftTask?.cancel()
        saveDraftTask = nil
        guard let draftID = gmailDraftID else { return }
        try? await GmailDraftService.shared.deleteDraft(draftID: draftID, accountID: accountID)
        gmailDraftID = nil
    }

    // MARK: - Reply Orchestration

    /// Prepares the VM fields for a reply and sends. Handles draft cleanup on success.
    func sendReplyMessage(
        replyHTML: String,
        to: String,
        cc: String,
        bcc: String,
        emailSubject: String,
        replyToMessageID: String?,
        parentMessageID: String? = nil,
        parentReferences: String? = nil,
        fileAttachments: [URL],
        editorInlineImages: [InlineImageAttachment],
        mailStore: MailStore
    ) async {
        if gmailDraftID == nil,
           let threadID,
           let saved = mailStore.replyDrafts[threadID] {
            gmailDraftID = saved.gmailDraftID
        }

        // Store cleanup context for send()'s onConfirm closure to use on success
        replyCleanupMailStore = mailStore
        replyCleanupDraftID = gmailDraftID

        let (processedHTML, images) = await Task.detached {
            InlineImageProcessor.extractInlineImages(from: replyHTML)
        }.value
        let sub = emailSubject.withReplyPrefix

        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = sub
        self.body = processedHTML
        self.isHTML = true
        self.inlineImages = images + editorInlineImages
        self.replyToMessageID = replyToMessageID
        self.parentMessageID = parentMessageID
        self.parentReferences = parentReferences
        self.attachments = fileAttachments

        await send()
    }

    /// Loads an existing reply draft from Gmail.
    /// Returns the body HTML if found, empty string if draft exists but has no body,
    /// or `nil` if the draft no longer exists (cleans up the local reference).
    func loadExistingDraft(
        mailStore: MailStore,
        loader: ((String, String) async throws -> GmailDraft?)?
    ) async -> String? {
        guard let threadID,
              let saved = mailStore.replyDrafts[threadID] else { return nil }
        do {
            let draft = try await loader?(saved.gmailDraftID, accountID)
            if let body = draft?.message?.body, !body.isEmpty {
                gmailDraftID = saved.gmailDraftID
                return body
            } else {
                gmailDraftID = saved.gmailDraftID
                return ""
            }
        } catch {
            mailStore.replyDrafts.removeValue(forKey: threadID)
            mailStore.saveReplyDrafts()
            return nil
        }
    }

    /// Debounced auto-save for reply drafts. Returns a cancellable Task.
    func scheduleReplyAutoSave(
        replyHTML: String,
        to: String,
        cc: String,
        bcc: String,
        emailSubject: String,
        replyToMessageID: String?,
        mailStore: MailStore,
        previousTask: Task<Void, Never>?
    ) -> Task<Void, Never>? {
        if replyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            previousTask?.cancel()
            if let threadID, mailStore.replyDrafts[threadID] != nil {
                mailStore.replyDrafts.removeValue(forKey: threadID)
                mailStore.saveReplyDrafts()
                if gmailDraftID != nil {
                    Task { [weak self] in await self?.discardDraft() }
                }
            }
            return nil
        }
        previousTask?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.gmailDraftID == nil,
               let threadID = self.threadID,
               let saved = mailStore.replyDrafts[threadID] {
                self.gmailDraftID = saved.gmailDraftID
            }
            let sub = emailSubject.withReplyPrefix
            self.to = to
            self.cc = cc
            self.bcc = bcc
            self.subject = sub
            self.body = replyHTML
            self.isHTML = true
            self.replyToMessageID = replyToMessageID
            await self.saveDraft()
        }
        return task
    }

    // MARK: - File Drop & Attachments

    enum FileDropResult {
        case image
        case attachment
        case unsupported(String)
    }

    /// Classifies a dropped file: images for inline insertion, compatible files as attachments,
    /// or unsupported with an error message. The caller is responsible for acting on the result.
    func handleFileDrop(_ url: URL) -> FileDropResult {
        if !url.isEmailCompatible {
            return .unsupported("Format non support\u{00E9}: .\(url.pathExtension)")
        } else if url.isImage {
            return .image
        } else {
            return .attachment
        }
    }

    /// Opens a file picker and returns selected URLs.
    /// NOTE: Callers in Views/ (ComposeView, ReplyBarView) need updating to use async call site.
    func openAttachmentPicker() async -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let response = await panel.begin()
        return response == .OK ? panel.urls : []
    }

    // MARK: - Reply Bar Computed

    var replyBodyIsEmpty: Bool {
        cachedStrippedText.isEmpty
    }

    var hasUserContent: Bool {
        !replyBodyIsEmpty || !attachments.isEmpty ||
        !cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !bcc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hasSavedDraft(for email: Email, in mailStore: MailStore) -> Bool {
        guard let threadID = email.gmailThreadID else { return false }
        return mailStore.replyDrafts[threadID] != nil
    }

    private(set) var collapsedPlaceholderText = "Write a reply..."

    func updateCollapsedPlaceholder(for email: Email, in mailStore: MailStore) {
        if !cachedStrippedText.isEmpty {
            let preview = String(cachedStrippedText.prefix(50))
            let ellipsis = cachedStrippedText.count > 50 ? "\u{2026}" : ""
            if !to.isEmpty {
                let recipientCount = splitAddresses(to).count + splitAddresses(cc).count
                if recipientCount > 1 {
                    collapsedPlaceholderText = "Reply All (\(recipientCount)) \u{00B7} \(preview)\(ellipsis)"
                } else {
                    let recipient = splitAddresses(to).first ?? ""
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

    // MARK: - Reply Bar Content

    /// Debounced update of the cached stripped text for `replyBodyIsEmpty` / `hasUserContent`.
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

    // MARK: - Reply Bar Lifecycle

    /// Resets all reply-bar state for a new email.
    func resetForEmail(_ email: Email) {
        saveTask?.cancel()
        saveTask = nil
        loadDraftTask?.cancel()
        loadDraftTask = nil
        stripTask?.cancel()
        stripTask = nil
        loadGeneration += 1

        to = ""
        cc = ""
        bcc = ""
        body = ""
        attachments = []
        showCc = false
        showBcc = false
        sendError = nil
        subjectOverride = nil
        cachedStrippedText = ""
        collapsedPlaceholderText = "Write a reply..."
        isSent = false
        isSending = false
        gmailDraftID = nil
        isInitialLoad = true
        isLoadingDraft = false

        threadID = email.gmailThreadID
    }

    /// Collapses the reply bar, discarding local and remote draft state.
    /// Does NOT touch `isExpanded` — that is view-local `@State`.
    func collapse(email: Email, mailStore: MailStore) {
        saveTask?.cancel()
        if let threadID = email.gmailThreadID {
            mailStore.replyDrafts.removeValue(forKey: threadID)
            mailStore.saveReplyDrafts()
        }
        if gmailDraftID != nil {
            Task { await discardDraft() }
        }
        to = ""
        cc = ""
        bcc = ""
        body = ""
        attachments = []
        showCc = false
        showBcc = false
        sendError = nil
        subjectOverride = nil
        cachedStrippedText = ""
        collapsedPlaceholderText = "Write a reply..."
    }

    /// Whether the user should be warned before discarding the reply bar.
    func shouldShowDiscardAlert(email: Email, mailStore: MailStore) -> Bool {
        hasSavedDraft(for: email, in: mailStore) || gmailDraftID != nil
    }

    // MARK: - Reply Bar Draft Loading

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
            let result = await loadExistingDraft(
                mailStore: mailStore,
                loader: loader
            )
            guard !Task.isCancelled, currentGen == loadGeneration else { return }
            if let draftBody = result, !draftBody.isEmpty {
                isInitialLoad = true
                body = draftBody
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

    // MARK: - Reply Bar Send / Schedule

    /// Sends a reply from the inline reply bar.
    func sendReplyFromBar(
        email: Email,
        editorInlineImages: [InlineImageAttachment],
        mailStore: MailStore
    ) async {
        sendError = nil
        saveTask?.cancel()

        await sendReplyMessage(
            replyHTML: body,
            to: to,
            cc: cc,
            bcc: bcc,
            emailSubject: subjectOverride ?? email.subject,
            replyToMessageID: email.gmailMessageID,
            parentMessageID: email.messageIDHeader,
            parentReferences: email.referencesHeader,
            fileAttachments: attachments,
            editorInlineImages: editorInlineImages,
            mailStore: mailStore
        )

        if let err = error {
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

        let bodySnapshot = body
        let (processedHTML, images) = await Task.detached {
            InlineImageProcessor.extractInlineImages(from: bodySnapshot)
        }.value

        self.subject = (subjectOverride ?? email.subject).withReplyPrefix
        self.body = processedHTML
        self.isHTML = true
        self.inlineImages = images + editorInlineImages
        self.replyToMessageID = email.gmailMessageID
        self.parentMessageID = email.messageIDHeader
        self.parentReferences = email.referencesHeader

        setReplyCleanupContext(mailStore: mailStore)
        await scheduleSend(at: date)

        if let err = error {
            sendError = err
        }
    }

    // MARK: - Reply Bar Auto-Save

    /// Unified auto-save with local-first persistence: writes to `mailStore.replyDrafts`
    /// immediately, then rate-limits the remote API save.
    func scheduleReplyAutoSaveUnified(email: Email, mailStore: MailStore) {
        guard !isInitialLoad, !isLoadingDraft else { return }

        let isEmpty = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty {
            saveTask?.cancel()
            if let threadID = email.gmailThreadID, mailStore.replyDrafts[threadID] != nil {
                mailStore.replyDrafts.removeValue(forKey: threadID)
                mailStore.saveReplyDrafts()
                if gmailDraftID != nil {
                    Task { [weak self] in await self?.discardDraft() }
                }
            }
            return
        }

        // Local-first: persist draft preview immediately
        if let threadID = email.gmailThreadID {
            let plain = (cachedStrippedText.isEmpty ? body.strippingHTML : cachedStrippedText).trimmingCharacters(in: .whitespacesAndNewlines)
            let draftID = gmailDraftID ?? mailStore.replyDrafts[threadID]?.gmailDraftID ?? ""
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
            saveTask = Task {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                lastDraftSaveDate = .now
                saveTask = scheduleReplyAutoSave(
                    replyHTML: body, to: to, cc: cc, bcc: bcc,
                    emailSubject: subjectOverride ?? email.subject,
                    replyToMessageID: email.gmailMessageID,
                    mailStore: mailStore, previousTask: nil
                )
            }
            return
        }

        lastDraftSaveDate = .now
        saveTask = scheduleReplyAutoSave(
            replyHTML: body, to: to, cc: cc, bcc: bcc,
            emailSubject: subjectOverride ?? email.subject,
            replyToMessageID: email.gmailMessageID,
            mailStore: mailStore, previousTask: saveTask
        )
    }

    // MARK: - Reply Bar File Helpers

    /// Routes a file drop through `handleFileDrop`, inserting images inline or appending attachments.
    func handleFileDropForReply(_ url: URL, editorState: WebRichTextEditorState) {
        switch handleFileDrop(url) {
        case .image:
            editorState.insertImage(from: url)
        case .attachment:
            attachments.append(url)
        case .unsupported(let message):
            showToast(message, type: .error)
        }
    }

    /// Opens a file picker and appends the selected files to `attachments`.
    func attachFilesForReply() async {
        let urls = await openAttachmentPicker()
        attachments.append(contentsOf: urls)
    }

    /// Cancels all reply-bar background tasks.
    func cancelReplyTasks() {
        saveTask?.cancel()
        loadDraftTask?.cancel()
        stripTask?.cancel()
    }

    // MARK: - Undo forwarding

    var currentUndoAction: PendingUndoAction? { UndoActionManager.shared.currentAction }
    var undoTimeRemaining: Double { UndoActionManager.shared.timeRemaining }

    func undoLastAction() {
        UndoActionManager.shared.undo()
    }

    // MARK: - Toast forwarding

    func showToast(_ message: String, type: ToastType = .info) {
        ToastManager.shared.show(message: message, type: type)
    }

    // MARK: - Helpers

    private func splitAddresses(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

}
