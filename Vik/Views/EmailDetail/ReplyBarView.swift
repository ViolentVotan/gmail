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
    var contacts: [StoredContact] = []

    @State private var composeVM: ComposeViewModel
    @State private var isExpanded = false
    @State private var showDiscardAlert = false
    @State private var sendHapticTrigger = false
    @State private var editorState = WebRichTextEditorState()
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
            // Smart reply / AI suggestion chips
            if composeVM.isLoadingReplies && composeVM.quickReplies.isEmpty && smartReplySuggestions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "apple.intelligence")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.quaternary)
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(.quaternary)
                            .frame(width: 80, height: 28)
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !composeVM.quickReplies.isEmpty {
                SuggestionChipRow(
                    suggestions: composeVM.quickReplies,
                    icon: .appleIntelligence,
                    style: .aiGradient
                ) { suggestion in
                    let escapedHTML = "<p>\(suggestion.htmlEscaped)</p>"
                    editorState.setHTML(escapedHTML)
                    composeVM.body = escapedHTML
                    if !isExpanded {
                        if composeVM.to.isEmpty { composeVM.to = email.sender.email }
                        composeVM.loadExistingDraftForReply(email: email, mailStore: mailStore, loader: onLoadDraft, editorState: editorState)
                        withAnimation(VikAnimation.springSnappy) { isExpanded = true }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !isExpanded && !smartReplySuggestions.isEmpty {
                SuggestionChipRow(suggestions: smartReplySuggestions) { suggestion in
                    if composeVM.to.isEmpty { composeVM.to = email.sender.email }
                    let html = "<p>\(suggestion.htmlEscaped)</p>"
                    composeVM.body = html
                    editorState.setHTML(html)
                    composeVM.loadExistingDraftForReply(email: email, mailStore: mailStore, loader: onLoadDraft, editorState: editorState)
                    withAnimation(VikAnimation.springSnappy) { isExpanded = true }
                    onSmartReplySelect?(suggestion)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isExpanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .floatingPanelStyle(cornerRadius: CornerRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
        )
        .background(ClickOutsideDetector(isExpanded: isExpanded, onClickOutside: { minimize() }))
        .onChange(of: composeVM.body) { _, newValue in
            composeVM.updateCachedText(html: newValue)
            composeVM.updateCollapsedPlaceholder(for: email, in: mailStore)
            composeVM.scheduleReplyAutoSaveUnified(email: email, mailStore: mailStore)
        }
        .animation(VikAnimation.springSnappy, value: composeVM.hasUserContent)
        .animation(VikAnimation.springSnappy, value: NetworkMonitor.shared.isConnected)
        .animation(VikAnimation.springSnappy, value: smartReplySuggestions.isEmpty)
        .task {
            try? await Task.sleep(for: ComposeViewModel.autoSaveGuardDelay)
            composeVM.isInitialLoad = false
        }
        .task(id: email.id) {
            await composeVM.resetForEmail(email, onGenerateQuickReplies: onGenerateQuickReplies)
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
        .composeTranslation(html: $composeVM.body, editorState: editorState)
        .onDisappear { composeVM.cancelReplyTasks() }
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        Button {
            if composeVM.to.isEmpty {
                composeVM.to = email.sender.email
            }
            composeVM.loadExistingDraftForReply(email: email, mailStore: mailStore, loader: onLoadDraft, editorState: editorState)
            withAnimation(VikAnimation.springSnappy) {
                isExpanded = true
            }
        } label: {
            HStack(spacing: 10) {
                Text(composeVM.collapsedPlaceholderText)
                    .font(Typography.body)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: composeVM.hasSavedDraft(for: email, in: mailStore) ? "arrow.uturn.forward" : "square.and.pencil")
                    .font(Typography.body)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.lg)
            .contentShape(Rectangle())
            .matchedGeometryEffect(id: "replyBar", in: replyBarNamespace)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reply to \(email.sender.name)")
        .accessibilityHint("Activate to expand reply editor")
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ComposeRecipientFields(composeVM: composeVM, contacts: contacts, compact: true)

                Divider().padding(.horizontal, Spacing.lg)

                HStack(spacing: 8) {
                    Text("Subject")
                        .font(Typography.captionRegular)
                        .foregroundStyle(.tertiary)
                        .frame(width: 50, alignment: .leading)

                    TextField("Subject", text: Binding(
                        get: { composeVM.subjectOverride ?? email.subject.withReplyPrefix },
                        set: { composeVM.subjectOverride = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(Typography.captionRegular)
                    .foregroundStyle(.primary)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.xs)

                Divider().padding(.horizontal, Spacing.lg)
            }
            .zIndex(10)

            WebRichTextEditor(
                state: editorState,
                htmlContent: $composeVM.body,
                placeholder: "Write a reply...",
                autoFocus: true,
                onFileDrop: { url in composeVM.handleFileDropForReply(url, editorState: editorState) },
                onOpenLink: onOpenLink
            )
            .frame(minHeight: 120, maxHeight: 400)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .strokeBorder(Color.accentColor.opacity(isEditorFocused ? 0.3 : 0), lineWidth: 1)
            )
            .overlay {
                if composeVM.isLoadingDraft {
                    ContentShimmerView()
                        .padding(Spacing.lg)
                        .transition(.opacity)
                }
            }
            .animation(VikAnimation.contentSwitch, value: composeVM.isLoadingDraft)
            .animation(VikAnimation.springSnappy, value: isEditorFocused)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.sm)
            .onAppear { isEditorFocused = true }
            .onDisappear { isEditorFocused = false }

            AttachmentChipRow(attachments: $composeVM.attachments)

            if !NetworkMonitor.shared.isConnected {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .font(Typography.captionRegular)
                    Text("You're offline — replies will be queued")
                        .font(Typography.captionRegular)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.xs)
                .transition(.opacity)
            }

            Divider().background(Color(.separatorColor))

            FormattingToolbar(state: editorState)

            Divider().background(Color(.separatorColor))

            // Error banner
            if let err = composeVM.sendError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Typography.captionRegular)
                    Text(err)
                        .font(Typography.captionRegular)
                    Spacer()
                    Button {
                        composeVM.sendError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(Typography.captionSmall)
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(SemanticColor.error)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityAddTraits(.isStaticText)
                .accessibilityElement(children: .combine)
            }

            ComposeActionBar(
                composeVM: composeVM,
                onMinimize: { minimize() },
                onDiscard: { discardAction() },
                onSend: {
                    sendHapticTrigger.toggle()
                    Task {
                        await composeVM.sendReplyFromBar(
                            email: email,
                            editorInlineImages: editorState.pendingInlineImages,
                            mailStore: mailStore
                        )
                    }
                },
                onSchedule: { date in
                    Task {
                        await composeVM.scheduleReplyFromBar(
                            at: date,
                            email: email,
                            editorInlineImages: editorState.pendingInlineImages,
                            mailStore: mailStore
                        )
                    }
                },
                onAttach: {
                    Task { await composeVM.attachFilesForReply() }
                },
                sendHapticTrigger: $sendHapticTrigger
            )
        }
        .matchedGeometryEffect(id: "replyBar", in: replyBarNamespace)
    }

    // MARK: - Actions

    private func discardAction() {
        if composeVM.shouldShowDiscardAlert(email: email, mailStore: mailStore) {
            showDiscardAlert = true
        } else {
            collapse()
        }
    }

    private func minimize() {
        withAnimation(VikAnimation.springSnappy) {
            isExpanded = false
        }
    }

    private func collapse() {
        composeVM.collapse(email: email, mailStore: mailStore)
        withAnimation(VikAnimation.springSnappy) {
            isExpanded = false
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
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
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
            if let eventWindow = event.window, eventWindow !== anchorWindow {
                return
            }
            let container = anchor.superview ?? anchor
            let clickInContainer = container.convert(event.locationInWindow, from: nil)
            if !container.bounds.contains(clickInContainer) {
                onClickOutside?()
            }
        }

        deinit {
            // dismantleNSView handles cleanup; this is a safety net for unexpected teardown paths.
            // NSViewRepresentable coordinators are always torn down on the main thread by SwiftUI.
            MainActor.assumeIsolated {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
            }
        }
    }
}
