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
    var isSending  = false
    var isSent     = false
    var error:     String?

    @ObservationIgnored let accountID:   String
    @ObservationIgnored var fromAddress: String
    @ObservationIgnored var gmailDraftID:     String?   // set once we've created a remote draft
    @ObservationIgnored private var saveDraftTask: Task<Void, Never>?
    @ObservationIgnored var threadID:         String?   // for replies
    @ObservationIgnored var replyToMessageID: String?   // for In-Reply-To / References headers
    @ObservationIgnored var attachmentURLs:   [URL] = []

    init(accountID: String, fromAddress: String, threadID: String? = nil) {
        self.accountID   = accountID
        self.fromAddress = fromAddress
        self.threadID    = threadID
    }

    deinit {
        saveDraftTask?.cancel()
    }

    // MARK: - Send

    var isAwaitingUndoSend = false

    func send() async {
        error = nil
        isAwaitingUndoSend = true
        isSending = true

        UndoActionManager.shared.schedule(
            label: "Sending...",
            onConfirm: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isAwaitingUndoSend = false
                    await self.executeSend()
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

    private func executeSend() async {
        do {
            _ = try await GmailSendService.shared.send(
                from:               fromAddress,
                to:                 splitAddresses(to),
                cc:                 splitAddresses(cc),
                bcc:                splitAddresses(bcc),
                subject:            subject,
                body:               body,
                isHTML:             isHTML,
                threadID:           threadID,
                referencesHeader:   replyToMessageID,
                inlineImages:       inlineImages,
                attachments:        attachmentURLs.isEmpty ? nil : attachmentURLs,
                accountID:          accountID
            )
            if let draftID = gmailDraftID {
                try? await GmailDraftService.shared.deleteDraft(draftID: draftID, accountID: accountID)
            }
            isSent = true
        } catch {
            self.error = error.localizedDescription
        }
        isSending = false
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

        let item = ScheduledSendItem(
            draftId: draftID,
            accountID: accountID,
            scheduledTime: scheduledDate,
            subject: subject,
            recipients: splitAddresses(to)
        )
        ScheduledSendStore.shared.add(item)
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
                let (processedBody, extractedImages) = InlineImageProcessor.extractInlineImages(from: body)
                let allImages = extractedImages + inlineImages

                if let draftID = gmailDraftID {
                    let draft = try await GmailDraftService.shared.updateDraft(
                        draftID:      draftID,
                        from:         fromAddress,
                        to:           splitAddresses(to),
                        cc:           splitAddresses(cc),
                        subject:      subject,
                        body:         processedBody,
                        isHTML:       isHTML,
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
                        subject:      subject,
                        body:         processedBody,
                        isHTML:       isHTML,
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
        attachmentURLs: [URL],
        editorInlineImages: [InlineImageAttachment],
        mailStore: MailStore
    ) async {
        if gmailDraftID == nil,
           let threadID,
           let saved = mailStore.replyDrafts[threadID] {
            gmailDraftID = saved.gmailDraftID
        }
        let draftIDToDelete = gmailDraftID

        let (processedHTML, images) = InlineImageProcessor.extractInlineImages(from: replyHTML)
        let sub = emailSubject.hasPrefix("Re:") ? emailSubject : "Re: \(emailSubject)"

        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = sub
        self.body = processedHTML
        self.isHTML = true
        self.inlineImages = images + editorInlineImages
        self.replyToMessageID = replyToMessageID
        self.attachmentURLs = attachmentURLs

        await send()

        if isSent {
            if let threadID {
                mailStore.replyDrafts.removeValue(forKey: threadID)
                mailStore.saveReplyDrafts()
            }
            if let gid = draftIDToDelete {
                mailStore.gmailDrafts.removeAll { $0.gmailDraftID == gid }
            }
        }
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
                    Task { await discardDraft() }
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
            let sub = emailSubject.hasPrefix("Re:") ? emailSubject : "Re: \(emailSubject)"
            self.to = to
            self.cc = cc
            self.bcc = bcc
            self.subject = sub
            self.body = replyHTML
            self.isHTML = true
            self.replyToMessageID = replyToMessageID
            await self.saveDraft()
            if let threadID = self.threadID, let draftID = self.gmailDraftID {
                let plain = replyHTML.strippingHTML.trimmingCharacters(in: .whitespacesAndNewlines)
                mailStore.replyDrafts[threadID] = .init(
                    gmailDraftID: draftID,
                    preview: String(plain.prefix(50))
                )
                mailStore.saveReplyDrafts()
            }
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

    // MARK: - Signature forwarding

    func signatureHTMLForAlias(
        _ aliasEmail: String,
        aliases: [GmailSendAs],
        fallbackPreferredEmail: String
    ) -> String {
        SignatureResolver.signatureHTMLForAlias(
            aliasEmail,
            aliases: aliases,
            fallbackPreferredEmail: fallbackPreferredEmail
        )
    }

    func replaceHTMLSignature(
        in bodyHTML: String,
        currentSignature: String,
        newSignature: String
    ) -> (body: String, signature: String) {
        SignatureResolver.replaceHTMLSignature(
            in: bodyHTML,
            currentSignature: currentSignature,
            newSignature: newSignature
        )
    }

    // MARK: - Helpers

    private func splitAddresses(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

}
