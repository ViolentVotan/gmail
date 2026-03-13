import SwiftUI

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

    @State private var replyHTML = ""
    @State private var isExpanded = false
    @State private var isSending = false
    @State private var sendError: String?
    @State private var attachments: [URL] = []
    @State private var saveTask: Task<Void, Never>?
    @State private var isInitialLoad = true
    @State private var isLoadingDraft = false
    @State private var showDiscardAlert = false
    @StateObject private var editorState = WebRichTextEditorState()
    @State private var composeVM: ComposeViewModel
    @State private var quickReplies: [String] = []
    @State private var isLoadingReplies = false
    @State private var replyTo = ""
    @State private var replyCc = ""
    @State private var replyBcc = ""
    @State private var showCc = false
    @State private var showBcc = false
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
        onSmartReplySelect: ((String) -> Void)? = nil
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
        self.composeVM = ComposeViewModel(
            accountID: accountID,
            fromAddress: fromAddress,
            threadID: email.gmailThreadID
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isExpanded && !smartReplySuggestions.isEmpty {
                SmartReplyChipsView(suggestions: smartReplySuggestions) { suggestion in
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
        .onChange(of: replyHTML) { _,_ in
            scheduleAutoSave()
        }
        .animation(SerifAnimation.springSnappy, value: replyBodyIsEmpty)
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                isInitialLoad = false
            }
        }
        .task(id: email.id) {
            isLoadingReplies = true
            quickReplies = await onGenerateQuickReplies?(email) ?? []
            isLoadingReplies = false
        }
        .alert("Discard reply?", isPresented: $showDiscardAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { collapse() }
        } message: {
            Text("Your reply draft will be permanently deleted.")
        }
    }

    private var replyBodyIsEmpty: Bool {
        replyHTML.strippingHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSavedDraft: Bool {
        guard let threadID = email.gmailThreadID else { return false }
        return mailStore.replyDrafts[threadID] != nil
    }

    private var collapsedPlaceholder: String {
        let currentText = replyHTML.strippingHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentText.isEmpty {
            let preview = String(currentText.prefix(50))
            return "\(preview)\(currentText.count > 50 ? "…" : "")"
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
            withAnimation(SerifAnimation.springSnappy) {
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
                recipientField(label: "To", text: $replyTo)
                Divider().padding(.horizontal, Spacing.lg)

                if showCc {
                    recipientField(label: "Cc", text: $replyCc)
                    Divider().padding(.horizontal, Spacing.lg)
                }

                if showBcc {
                    recipientField(label: "Bcc", text: $replyBcc)
                    Divider().padding(.horizontal, Spacing.lg)
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button { withAnimation { showCc.toggle() } } label: {
                        Text("Cc")
                            .font(Typography.caption)
                            .foregroundStyle(showCc ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    Button { withAnimation { showBcc.toggle() } } label: {
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

            WebRichTextEditor(
                state: editorState,
                htmlContent: $replyHTML,
                placeholder: "Write a reply...",
                autoFocus: true,
                onFileDrop: { url in handleFileDrop(url) },
                onOpenLink: onOpenLink
            )
            .frame(minHeight: 120, maxHeight: 200)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.sm)

            if !attachments.isEmpty {
                Divider().background(Color(.separatorColor))
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
                            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                            .glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.sm))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
                }
            }

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
                        .foregroundStyle(.red)
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

                    Button { Task { await sendReply() } } label: {
                        if isSending {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Text("Send")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(isSending)
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
            Group {
                if #available(macOS 26.0, *) {
                    GlassEffectContainer {
                        quickReplyChipContent
                    }
                } else {
                    quickReplyChipContent
                }
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

            ForEach(Array(quickReplies.enumerated()), id: \.element) { index, suggestion in
                Button {
                    let escaped = suggestion
                        .replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                    editorState.setHTML("<p>\(escaped)</p>")
                    replyHTML = "<p>\(escaped)</p>"
                } label: {
                    Text(suggestion)
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .glassEffect(.regular, in: .capsule)
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
            withAnimation(SerifAnimation.springGentle.delay(Double(i) * 0.1)) {
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
        isSending = true
        sendError = nil
        saveTask?.cancel()

        await composeVM.sendReplyMessage(
            replyHTML: replyHTML,
            to: replyTo,
            cc: replyCc,
            bcc: replyBcc,
            emailSubject: email.subject,
            replyToMessageID: email.gmailMessageID,
            attachmentURLs: attachments,
            editorInlineImages: editorState.pendingInlineImages,
            mailStore: mailStore
        )
        isSending = false

        if composeVM.isSent {
            ToastManager.shared.show(message: "Reply sent", type: .success)
            collapse()
        } else {
            sendError = composeVM.error
        }
    }

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

    private func loadExistingDraft() {
        guard email.gmailThreadID != nil,
              mailStore.replyDrafts[email.gmailThreadID!] != nil else { return }
        isLoadingDraft = true
        Task {
            let result = await composeVM.loadExistingDraft(
                mailStore: mailStore,
                loader: onLoadDraft
            )
            if let body = result, !body.isEmpty {
                isInitialLoad = true
                replyHTML = body
                editorState.setHTML(body)
                isLoadingDraft = false
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.5))
                    isInitialLoad = false
                }
            } else if result != nil {
                isLoadingDraft = false
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
        withAnimation(SerifAnimation.springSnappy) {
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
        withAnimation(SerifAnimation.springSnappy) {
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

    class Coordinator {
        weak var anchorView: NSView?
        var isExpanded = false
        var onClickOutside: (() -> Void)?
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handleClick(event)
                return event
            }
        }

        private func handleClick(_ event: NSEvent) {
            guard isExpanded, let anchor = anchorView, let anchorWindow = anchor.window else { return }
            // Ignore clicks in popover windows (color picker, link popover, alerts, etc.)
            if let eventWindow = event.window, eventWindow !== anchorWindow {
                return
            }
            let clickInAnchor = anchor.convert(event.locationInWindow, from: nil)
            if !anchor.bounds.contains(clickInAnchor) {
                // NSEvent monitors fire on the main thread
                nonisolated(unsafe) let action = onClickOutside
                MainActor.assumeIsolated { action?() }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
