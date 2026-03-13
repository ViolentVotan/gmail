import SwiftUI

struct ComposeView: View {
    var mailStore: MailStore
    let draftId: UUID
    let accountID: String
    let fromAddress: String
    let mode: ComposeMode
    let sendAsAliases: [GmailSendAs]
    let signatureForNew: String
    let signatureForReply: String
    let contacts: [StoredContact]
    let onDiscard: () -> Void
    var onOpenLink: ((URL) -> Void)?

    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var bodyHTML = ""
    @State private var showCc = false
    @State private var showBcc = false
    @State private var sendError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var attachments: [URL] = []
    @State private var didApplyMode = false
    @State private var isInitialLoad = true
    @State private var selectedAliasEmail: String
    @State private var currentSignatureHTML: String = ""
    @State private var showDiscardAlert = false
    @StateObject private var editorState = WebRichTextEditorState()
    @State private var composeVM: ComposeViewModel

    init(
        mailStore: MailStore,
        draftId: UUID,
        accountID: String,
        fromAddress: String,
        mode: ComposeMode = .new,
        sendAsAliases: [GmailSendAs] = [],
        signatureForNew: String = "",
        signatureForReply: String = "",
        contacts: [StoredContact] = [],
        onDiscard: @escaping () -> Void,
        onOpenLink: ((URL) -> Void)? = nil
    ) {
        self.mailStore         = mailStore
        self.draftId           = draftId
        self.accountID         = accountID
        self.fromAddress       = fromAddress
        self.mode              = mode
        self.sendAsAliases     = sendAsAliases
        self.signatureForNew   = signatureForNew
        self.signatureForReply = signatureForReply
        self.contacts          = contacts
        self.onDiscard         = onDiscard
        self.onOpenLink        = onOpenLink
        self._selectedAliasEmail = State(initialValue: fromAddress)
        self.composeVM         = ComposeViewModel(
            accountID: accountID,
            fromAddress: fromAddress
        )
    }

    private var draft: Email? {
        mailStore.emails.first { $0.id == draftId }
            ?? mailStore.gmailDrafts.first { $0.id == draftId }
    }

    var body: some View {
        VStack(spacing: 0) {
            composeToolbar

            Divider()

            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    if sendAsAliases.count > 1 {
                        fromField
                        Divider().padding(.horizontal, 24)
                    }

                    AutocompleteTextField(label: "To", placeholder: "Recipients", text: $to, contacts: contacts)
                    Divider().padding(.horizontal, 24)

                    if showCc {
                        AutocompleteTextField(label: "Cc", placeholder: "Cc recipients", text: $cc, contacts: contacts)
                        Divider().padding(.horizontal, 24)
                    }

                    if showBcc {
                        AutocompleteTextField(label: "Bcc", placeholder: "Bcc recipients", text: $bcc, contacts: contacts)
                        Divider().padding(.horizontal, 24)
                    }

                    composeField(label: "Subject", text: $subject, placeholder: "Subject")
                    Divider().padding(.horizontal, 24)
                }
            }
            .zIndex(10)

            WebRichTextEditor(
                state: editorState,
                htmlContent: $bodyHTML,
                placeholder: "Write your message...",
                autoFocus: true,
                onFileDrop: { url in handleFileDrop(url) },
                onOpenLink: onOpenLink
            )
            .padding(.horizontal, 20)
            .padding(.top, 4)

            if !attachments.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: url.sfSymbolIcon)
                                    .font(Typography.captionRegular)
                                Text(url.lastPathComponent)
                                    .font(Typography.captionRegular)
                                    .lineLimit(1)
                                Button { attachments.removeAll { $0 == url } } label: {
                                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                }
            }

            Divider()

            FormattingToolbar(state: editorState)

            Divider()

            if composeVM.isSending, let _ = UndoActionManager.shared.currentAction {
                HStack {
                    Text("Sending in \(Int(UndoActionManager.shared.timeRemaining))s...")
                        .font(Typography.subheadRegular)
                    Spacer()
                    Button("Undo") {
                        UndoActionManager.shared.undo()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.yellow.opacity(0.1))

                Divider()
            }

            composeActions
        }
        .onAppear { loadDraft() }
        .onChange(of: composeVM.isSent) { _, isSent in
            guard isSent else { return }
            saveTask?.cancel()
            onDiscard()
        }
        .onChange(of: composeVM.error) { _, err in
            sendError = err
        }
        .onChange(of: to)       { _, _ in scheduleAutoSave() }
        .onChange(of: cc)       { _, _ in scheduleAutoSave() }
        .onChange(of: bcc)      { _, _ in scheduleAutoSave() }
        .onChange(of: subject)  { _, _ in scheduleAutoSave() }
        .onChange(of: bodyHTML) { _, _ in scheduleAutoSave() }
        .onChange(of: selectedAliasEmail) { _, newEmail in
            composeVM.fromAddress = newEmail
            replaceSignature(for: newEmail)
        }
        .alert("Discard draft?", isPresented: $showDiscardAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) {
                saveTask?.cancel()
                Task { await composeVM.discardDraft() }
                onDiscard()
            }
        } message: {
            Text("This draft will be permanently deleted.")
        }
    }

    // MARK: - Draft

    private func loadDraft() {
        let existingDraft = draft
        let hasExistingContent = !(existingDraft?.body.isEmpty ?? true)

        if let draft = existingDraft {
            to      = draft.recipients.map(\.email).joined(separator: ", ")
            cc      = draft.cc.map(\.email).joined(separator: ", ")
            subject = draft.subject == "(No subject)" ? "" : draft.subject
            bodyHTML = draft.body
            if let gid = draft.gmailDraftID {
                composeVM.gmailDraftID = gid
            }
            if !draft.cc.isEmpty { showCc = true }
        }

        // Don't apply mode initializer on existing drafts — it would overwrite body with signature
        if !hasExistingContent {
            guard !didApplyMode else { isInitialLoad = false; return }
            didApplyMode = true

            let fields = ComposeModeInitializer.apply(
                mode: mode,
                signatureForNew: signatureForNew,
                signatureForReply: signatureForReply,
                aliases: sendAsAliases
            )

            to                   = fields.to.isEmpty ? to : fields.to
            cc                   = fields.cc.isEmpty ? cc : fields.cc
            showCc               = fields.showCc || showCc
            subject              = fields.subject.isEmpty ? subject : fields.subject
            bodyHTML              = fields.bodyHTML.isEmpty ? bodyHTML : fields.bodyHTML
            currentSignatureHTML = fields.currentSignatureHTML
            if let tid = fields.threadID          { composeVM.threadID = tid }
            if let mid = fields.replyToMessageID  { composeVM.replyToMessageID = mid }
        }

        // Delay clearing isInitialLoad so the WebView's didFinish → setHTML → contentChanged
        // cycle doesn't trigger a spurious auto-save that could corrupt inline images.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            isInitialLoad = false
        }
    }

    private func scheduleAutoSave() {
        guard !isInitialLoad else { return }
        mailStore.updateDraft(id: draftId, subject: subject, body: bodyHTML, to: to, cc: cc)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            composeVM.to      = to
            composeVM.cc      = cc
            composeVM.bcc     = bcc
            composeVM.subject = subject
            composeVM.body    = bodyHTML
            composeVM.isHTML  = true
            await composeVM.saveDraft()
            // Persist gmailDraftID back to the Email in mailStore so it survives view destruction
            if let gid = composeVM.gmailDraftID {
                mailStore.setGmailDraftID(gid, for: draftId)
                // Update reply draft preview if this draft is linked to a quick reply
                if let threadID = composeVM.threadID,
                   mailStore.replyDrafts[threadID] != nil {
                    let plain = bodyHTML.strippingHTML.trimmingCharacters(in: .whitespacesAndNewlines)
                    mailStore.replyDrafts[threadID] = .init(
                        gmailDraftID: gid,
                        preview: String(plain.prefix(50))
                    )
                    mailStore.saveReplyDrafts()
                }
            }
        }
    }

    // MARK: - Send

    private func sendEmail() async {
        guard !to.isEmpty, !subject.isEmpty else { return }
        sendError = nil

        // Extract inline images from HTML (data: → cid:)
        let (processedHTML, images) = InlineImageProcessor.extractInlineImages(from: bodyHTML)
        composeVM.to             = to
        composeVM.cc             = cc
        composeVM.bcc            = bcc
        composeVM.subject        = subject
        composeVM.body           = processedHTML
        composeVM.isHTML         = true
        composeVM.inlineImages   = images + editorState.pendingInlineImages
        composeVM.attachmentURLs = attachments
        await composeVM.send()
        // send() returns immediately after scheduling the undo action.
        // Dismissal and error handling are driven by onChange(of: composeVM.isSent)
        // and onChange(of: composeVM.error) below.
    }

    // MARK: - File Drop & Attachments

    private func handleFileDrop(_ url: URL) {
        switch composeVM.handleFileDrop(url) {
        case .image:
            editorState.insertImage(from: url)
        case .attachment:
            attachments.append(url)
        case .unsupported(let message):
            ToastManager.shared.show(message: message, type: .error)
        }
    }

    private func attachFiles() {
        composeVM.openAttachmentPicker { urls in
            attachments += urls
        }
    }

    // MARK: - Toolbar

    private var composeToolbar: some View {
        HStack(spacing: 12) {
            Spacer()

            toolbarButton(icon: "paperclip", label: "Attach") { attachFiles() }

            Button {
                showCc.toggle()
            } label: {
                Text("Cc")
                    .font(Typography.subhead)
                    .foregroundStyle(showCc ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show Cc")

            Button {
                showBcc.toggle()
            } label: {
                Text("Bcc")
                    .font(Typography.subhead)
                    .foregroundStyle(showBcc ? Color.accentColor : Color.secondary)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show Bcc")

            Divider().frame(height: 16)

            toolbarButton(icon: "trash", label: "Discard") {
                showDiscardAlert = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: - Bottom actions

    private var composeActions: some View {
        HStack(spacing: 12) {
            Button {
                showDiscardAlert = true
            } label: {
                Text("Discard")
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            if let err = sendError {
                Text(err)
                    .font(Typography.captionRegular)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Spacer()

            ScheduleSendButton(
                onSend: { Task { await sendEmail() } },
                onSchedule: { date in Task { await composeVM.scheduleSend(at: date) } },
                isSending: composeVM.isSending
            )
            .disabled(composeVM.isSending || to.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - From field

    private var fromField: some View {
        HStack(spacing: 10) {
            Text("From")
                .font(Typography.subhead)
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .leading)

            Picker("", selection: $selectedAliasEmail) {
                ForEach(sendAsAliases, id: \.sendAsEmail) { alias in
                    Text(aliasLabel(alias)).tag(alias.sendAsEmail)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(Typography.body)
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private func aliasLabel(_ alias: GmailSendAs) -> String {
        if let name = alias.displayName, !name.isEmpty {
            return "\(name) <\(alias.sendAsEmail)>"
        }
        return alias.sendAsEmail
    }

    // MARK: - Signature helpers

    private func replaceSignature(for aliasEmail: String) {
        let isReplyOrForward: Bool
        switch mode {
        case .new: isReplyOrForward = false
        default:   isReplyOrForward = true
        }
        let preferredEmail = isReplyOrForward ? signatureForReply : signatureForNew
        let newSig = SignatureResolver.signatureHTMLForAlias(
            aliasEmail,
            aliases: sendAsAliases,
            fallbackPreferredEmail: preferredEmail
        )
        let result = SignatureResolver.replaceHTMLSignature(
            in: bodyHTML,
            currentSignature: currentSignatureHTML,
            newSignature: newSig
        )
        bodyHTML = result.body
        currentSignatureHTML = result.signature
        // Update the editor content
        editorState.setHTML(bodyHTML)
    }

    // MARK: - Fields

    private func composeField(label: String, text: Binding<String>, placeholder: String = "") -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Typography.subhead)
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .leading)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
}
