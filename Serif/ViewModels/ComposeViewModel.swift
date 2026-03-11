import SwiftUI
import Observation

/// Drives the compose / reply / draft editing flow.
@Observable
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

    // MARK: - Send

    func send() async {
        isSending = true
        error     = nil
        defer { isSending = false }
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
                try? await GmailSendService.shared.deleteDraft(draftID: draftID, accountID: accountID)
            }
            isSent = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Draft

    func saveDraft() async {
        // Cancel any previous in-flight save so we don't get double creates
        saveDraftTask?.cancel()

        let task = Task {
            guard !Task.isCancelled else { return }
            do {
                // Extract inline data: URLs → cid: + MIME parts for proper Gmail storage
                let (processedBody, extractedImages) = InlineImageProcessor.extractInlineImages(from: body)
                let allImages = extractedImages + inlineImages

                if let draftID = gmailDraftID {
                    let draft = try await GmailSendService.shared.updateDraft(
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
                    gmailDraftID = draft.id
                } else {
                    let draft = try await GmailSendService.shared.createDraft(
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
                    gmailDraftID = draft.id
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
        try? await GmailSendService.shared.deleteDraft(draftID: draftID, accountID: accountID)
        gmailDraftID = nil
    }

    // MARK: - Helpers

    private func splitAddresses(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var canSend: Bool { !to.isEmpty && !subject.isEmpty }
}
