import SwiftUI
import Translation

struct ReplyBarView: View {
    let email: Email
    let accountID: String
    let fromAddress: String
    let mailStore: MailStore
    var onOpenLink: ((URL) -> Void)?
    var onGenerateQuickReplies: ((Email) async -> [String])?
    var onLoadDraft: ((String, String) async throws -> GmailDraft?)?
    var smartReplySuggestions: [String] = []
    var onSmartReplySelect: ((String) -> Void)?
    var contacts: [StoredContact] = []

    @State private var replyHTML = ""
    @State private var isExpanded = false
    @State private var sendError: String?
    @State private var showTranslation = false
    @State private var translationSourceText = ""
    @State private var attachments: [URL] = []
    @State private var saveTask: Task<Void, Never>?
    @State private var loadDraftTask: Task<Void, Never>?
    @State private var loadGeneration = 0
    @State private var isInitialLoad = true
    @State private var isLoadingDraft = false
    @State private var showDiscardAlert = false
    @State private var editorState = WebRichTextEditorState()
    @State private var composeVM: ComposeViewModel
    @State private var quickReplies: [String] = []
    @State private var isLoadingReplies = false
    @State private var replyTo = ""
    @State private var replyCc = ""
    @State private var replyBcc = ""
    @State private var showCc = false
    @State private var showBcc = false
    @State private var cachedStrippedText = ""
    @State private var isEditorFocused = false
    @Namespace private var replyBarNamespace
    init(
        email: Email,
        accountID: String,
        fromAddress: String,
        mailStore: MailStore,
        onOpenLink: ((URL) -> Void)? = nil,
        onGenerateQuickReplies: ((Email) async -> [String])? = nil,
        onLoadDraft: ((String, String) async throws -> GmailDraft?)? = nil,
        smartReplySuggestions: [String] = [],
        onSmartReplySelect: ((String) -> Void)? = nil,
        contacts: [StoredContact] = []
    ) {
        self.email = email
        self.accountID = accountID
        self.fromAddress = fromAddress
        self.mailStore = mailStore
        self.onOpenLink = onOpenLink
        self.onGenerateQuickReplies = onGenerateQuickReplies
        self.onLoadDraft = onLoadDraft
        self.smartReplySuggestions = smartReplySuggestions
        self.onSmartReplySelect = onSmartReplySelect
        self.contacts = contacts
        self._composeVM = State(initialValue: ComposeViewModel(
            accountID: accountID,
            fromAddress: fromAddress,
            threadID: email.gmailThreadID
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isExpanded && !smartReplySuggestions.isEmpty {
                SmartReplyChipsView(suggestions: smartReplySuggestions) { suggestion in
                    if replyTo.isEmpty {
                        replyTo = email.sender.email
                    }
                    let html = "<p>\(suggestion.htmlEscaped)</p>"
                    replyHTML = html
                    editorState.setHTML(html)
                    loadExistingDraft()
                    withAnimation(VikAnimation.springSnappy) {
                        isExpanded = true
                    }
                    onSmartReplySelect?(suggestion)
                }
            }
            if isExpanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .floatingPanelStyle(cornerRadius: CornerRadius.lg)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.lg)
                .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
        )
        .background(ClickOutsideDetector(isExpanded: isExpanded, onClickOutside: { minimize() }))
        .onChange(of: replyHTML) { _, _ in
            cachedStrippedText = replyHTML.strippingHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            scheduleAutoSave()
        }
        .animation(VikAnimation.springSnappy, value: replyBodyIsEmpty)
        .task {
            try? await Task.sleep(for: .seconds(0.5))
            isInitialLoad = false
        }
        .task(id: email.id) {
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
        .onChange(of: composeVM.isSent) { _, isSent in
            guard isSent else { return }
            if !composeVM.wasScheduled {
                composeVM.showToast("Reply sent", type: .success)
            }
            collapse()
        }
        .alert("Discard reply?", isPresented: $showDiscardAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { collapse() }
        } message: {
            Text("Your reply draft will be permanently deleted.")
        }
        .onChange(of: editorState.translationRequested) { _, requested in
            guard requested else { return }
            editorState.translationRequested = false
            translationSourceText = replyHTML.strippingHTML
            showTranslation = true
        }
        .translationPresentation(isPresented: $showTranslation, text: translationSourceText) { translated in
            guard !translated.isEmpty else { return }
            let html = translated.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "<p>\($0)</p>" }
                .joined()
            editorState.setHTML(html)
            replyHTML = html
        }
        .onDisappear { saveTask?.cancel(); loadDraftTask?.cancel() }
    }

    private var replyBodyIsEmpty: Bool {
        cachedStrippedText.isEmpty
    }

    private var hasSavedDraft: Bool {
        guard let threadID = email.gmailThreadID else { return false }
        return mailStore.replyDrafts[threadID] != nil
    }

    private var collapsedPlaceholder: String {
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

    // MARK: - Collapsed

    private var collapsedContent: some View {
        Button {
            if replyTo.isEmpty {
                replyTo = email.sender.email
            }
            loadExistingDraft()
            withAnimation(VikAnimation.springSnappy) {
                isExpanded = true
            }
        } label: {
            HStack(spacing: 10) {
                if !quickReplies.isEmpty {
                    Image(systemName: "apple.intelligence")
                        .font(Typography.body)
                        .foregroundStyle(appleIntelligenceGradient)
                }
                Text(collapsedPlaceholder)
                    .font(Typography.body)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: hasSavedDraft ? "arrow.uturn.forward" : "square.and.pencil")
                    .font(Typography.body)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.lg)
            .contentShape(Rectangle())
            .matchedGeometryEffect(id: "replyBar", in: replyBarNamespace)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(spacing: 0) {
            if !quickReplies.isEmpty {
                quickReplyChips
            }

            // Recipient fields
            VStack(spacing: 0) {
                AutocompleteTextField(label: "To", placeholder: "Recipients", text: $replyTo, contacts: contacts)
                Divider().padding(.horizontal, Spacing.lg)

                if showCc {
                    AutocompleteTextField(label: "Cc", placeholder: "Cc recipients", text: $replyCc, contacts: contacts)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    Divider().padding(.horizontal, Spacing.lg)
                }

                if showBcc {
                    AutocompleteTextField(label: "Bcc", placeholder: "Bcc recipients", text: $replyBcc, contacts: contacts)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    Divider().padding(.horizontal, Spacing.lg)
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button { withAnimation(VikAnimation.springSnappy) { showCc.toggle() } } label: {
                        Text("Cc")
                            .font(Typography.caption)
                            .foregroundStyle(showCc ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    Button { withAnimation(VikAnimation.springSnappy) { showBcc.toggle() } } label: {
                        Text("Bcc")
                            .font(Typography.caption)
                            .foregroundStyle(showBcc ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)

                Divider().padding(.horizontal, Spacing.lg)
            }
            .zIndex(10)

            WebRichTextEditor(
                state: editorState,
                htmlContent: $replyHTML,
                placeholder: "Write a reply...",
                autoFocus: true,
                onFileDrop: { url in handleFileDrop(url) },
                onOpenLink: onOpenLink
            )
            .frame(minHeight: 120, maxHeight: 200)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .strokeBorder(Color.accentColor.opacity(isEditorFocused ? 0.3 : 0), lineWidth: 1)
            )
            .animation(VikAnimation.springSnappy, value: isEditorFocused)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.sm)
            .onAppear { isEditorFocused = true }
            .onDisappear { isEditorFocused = false }

            AttachmentChipRow(attachments: $attachments)

            Divider().background(Color(.separatorColor))

            FormattingToolbar(state: editorState)

            Divider().background(Color(.separatorColor))

            HStack(spacing: 12) {
                Button { minimize() } label: {
                    Image(systemName: "chevron.down")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Minimize")
                .keyboardShortcut(.escape, modifiers: [])

                Button { attachFiles() } label: {
                    Image(systemName: "paperclip")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Attach file")

                if let err = sendError {
                    Text(err)
                        .font(Typography.captionRegular)
                        .foregroundStyle(SemanticColor.error)
                        .lineLimit(1)
                }

                Spacer()

                if !replyBodyIsEmpty {
                    Button { discardAction() } label: {
                        Text("Discard")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))

                    ScheduleSendButton(
                        onSend: { Task { await sendReply() } },
                        onSchedule: { date in Task { await scheduleReply(at: date) } },
                        isSending: composeVM.isSending
                    )
                    .disabled(composeVM.isSending)
                    .keyboardShortcut(.return, modifiers: .command)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        }
        .matchedGeometryEffect(id: "replyBar", in: replyBarNamespace)
    }

    // MARK: - Apple Intelligence Colors

    private enum AppleIntelligenceColors {
        static let purple = Color(hex: "#6E6CE8")
        static let blue = Color(hex: "#54C0F0")
        static let orange = Color(hex: "#E8754A")
    }

    // MARK: - Quick Reply Chips

    private var appleIntelligenceGradient: LinearGradient {
        LinearGradient(
            colors: [AppleIntelligenceColors.purple, AppleIntelligenceColors.blue, AppleIntelligenceColors.orange],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    @State private var visibleChipCount = 0

    private var quickReplyChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer {
                quickReplyChipContent
            }
        }
        .onAppear { animateChips() }
        .onChange(of: quickReplies) { _, _ in animateChips() }
    }

    private var quickReplyChipContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.intelligence")
                .font(Typography.subheadRegular)
                .foregroundStyle(appleIntelligenceGradient)
                .opacity(visibleChipCount > 0 ? 1 : 0)
                .scaleEffect(visibleChipCount > 0 ? 1 : 0.5)

            ForEach(Array(quickReplies.enumerated()), id: \.offset) { index, suggestion in
                Button {
                    let escapedHTML = "<p>\(suggestion.htmlEscaped)</p>"
                    editorState.setHTML(escapedHTML)
                    replyHTML = escapedHTML
                } label: {
                    Text(suggestion)
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .overlay(
                            Capsule()
                                .strokeBorder(appleIntelligenceGradient, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .opacity(index < visibleChipCount ? 1 : 0)
                .offset(x: index < visibleChipCount ? 0 : 15)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    private func animateChips() {
        visibleChipCount = 0
        guard !quickReplies.isEmpty else { return }
        for i in 0..<quickReplies.count {
            withAnimation(VikAnimation.springGentle.delay(Double(i) * 0.1)) {
                visibleChipCount = i + 1
            }
        }
    }

    // MARK: - Recipient Field

    private func recipientField(label: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Typography.subhead)
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .leading)

            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(Typography.subheadRegular)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Actions

    private func discardAction() {
        if hasSavedDraft || composeVM.gmailDraftID != nil {
            showDiscardAlert = true
        } else {
            collapse()
        }
    }

    private func sendReply() async {
        sendError = nil
        saveTask?.cancel()

        await composeVM.sendReplyMessage(
            replyHTML: replyHTML,
            to: replyTo,
            cc: replyCc,
            bcc: replyBcc,
            emailSubject: email.subject,
            replyToMessageID: email.gmailMessageID,
            parentMessageID: email.messageIDHeader,
            parentReferences: email.referencesHeader,
            attachmentURLs: attachments,
            editorInlineImages: editorState.pendingInlineImages,
            mailStore: mailStore
        )

        if let error = composeVM.error {
            sendError = error
        }
    }

    private func scheduleReply(at date: Date) async {
        sendError = nil
        saveTask?.cancel()

        // Sync reply fields to the VM before scheduleSend calls saveDraft
        let (processedHTML, images) = InlineImageProcessor.extractInlineImages(from: replyHTML)
        composeVM.to = replyTo
        composeVM.cc = replyCc
        composeVM.bcc = replyBcc
        composeVM.subject = email.subject.withReplyPrefix
        composeVM.body = processedHTML
        composeVM.isHTML = true
        composeVM.inlineImages = images + editorState.pendingInlineImages
        composeVM.replyToMessageID = email.gmailMessageID
        composeVM.parentMessageID = email.messageIDHeader
        composeVM.parentReferences = email.referencesHeader
        composeVM.attachmentURLs = attachments

        // Set cleanup context so scheduleSend can clean up reply drafts
        composeVM.setReplyCleanupContext(mailStore: mailStore)

        await composeVM.scheduleSend(at: date)

        if let error = composeVM.error {
            sendError = error
        }
    }

    private func handleFileDrop(_ url: URL) {
        switch composeVM.handleFileDrop(url) {
        case .image:
            editorState.insertImage(from: url)
        case .attachment:
            attachments.append(url)
        case .unsupported(let message):
            composeVM.showToast(message, type: .error)
        }
    }

    private func attachFiles() {
        Task {
            let urls = await composeVM.openAttachmentPicker()
            attachments += urls
        }
    }

    private func loadExistingDraft() {
        guard let threadID = email.gmailThreadID,
              mailStore.replyDrafts[threadID] != nil else { return }
        isLoadingDraft = true
        loadDraftTask?.cancel()
        let currentGen = loadGeneration
        loadDraftTask = Task {
            let result = await composeVM.loadExistingDraft(
                mailStore: mailStore,
                loader: onLoadDraft
            )
            guard !Task.isCancelled, currentGen == loadGeneration else { return }
            if let body = result, !body.isEmpty {
                isInitialLoad = true
                replyHTML = body
                editorState.setHTML(body)
                isLoadingDraft = false
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled, currentGen == loadGeneration else { return }
                isInitialLoad = false
            } else {
                isLoadingDraft = false
            }
        }
    }

    private func scheduleAutoSave() {
        guard !isInitialLoad, !isLoadingDraft else { return }
        saveTask = composeVM.scheduleReplyAutoSave(
            replyHTML: replyHTML,
            to: replyTo,
            cc: replyCc,
            bcc: replyBcc,
            emailSubject: email.subject,
            replyToMessageID: email.gmailMessageID,
            mailStore: mailStore,
            previousTask: saveTask
        )
    }


    private func minimize() {
        withAnimation(VikAnimation.springSnappy) {
            isExpanded = false
        }
    }

    private func collapse() {
        saveTask?.cancel()
        if let threadID = email.gmailThreadID {
            mailStore.replyDrafts.removeValue(forKey: threadID)
            mailStore.saveReplyDrafts()
        }
        if composeVM.gmailDraftID != nil {
            Task { await composeVM.discardDraft() }
        }
        withAnimation(VikAnimation.springSnappy) {
            isExpanded = false
            replyHTML = ""
            replyTo = ""
            replyCc = ""
            replyBcc = ""
            showCc = false
            showBcc = false
            attachments = []
            sendError = nil
        }
    }
}

// MARK: - Click Outside Detector

/// NSViewRepresentable that monitors mouse clicks and fires a callback
/// when the click lands outside of its own parent view hierarchy.
private struct ClickOutsideDetector: NSViewRepresentable {
    let isExpanded: Bool
    let onClickOutside: () -> Void

    private class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func cursorUpdate(with event: NSEvent) {}
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        context.coordinator.anchorView = view
        context.coordinator.onClickOutside = onClickOutside
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isExpanded = isExpanded
        context.coordinator.onClickOutside = onClickOutside
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor class Coordinator {
        weak var anchorView: NSView?
        var isExpanded = false
        var onClickOutside: (() -> Void)?
        nonisolated(unsafe) private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                // NSEvent local monitors fire on the main thread
                MainActor.assumeIsolated { self?.handleClick(event) }
                return event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handleClick(_ event: NSEvent) {
            guard isExpanded, let anchor = anchorView, let anchorWindow = anchor.window else { return }
            // Ignore clicks in popover windows (color picker, link popover, alerts, etc.)
            if let eventWindow = event.window, eventWindow !== anchorWindow {
                return
            }
            // The anchor is a zero-size PassthroughView. Walk up the view
            // hierarchy to find the actual container (the SwiftUI host view
            // that has a meaningful frame encompassing the reply bar).
            let container = anchor.superview ?? anchor
            let clickInContainer = container.convert(event.locationInWindow, from: nil)
            if !container.bounds.contains(clickInContainer) {
                onClickOutside?()
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
