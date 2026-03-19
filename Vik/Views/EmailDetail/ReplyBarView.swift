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

    @State private var manager: ReplyBarManager
    @State private var isExpanded = false
    @State private var showDiscardAlert = false
    @State private var showTranslation = false
    @State private var translationSourceText = ""
    @State private var isEditorFocused = false
    @State private var sendHapticTrigger = false
    @State private var editorState = WebRichTextEditorState()
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
        self._manager = State(initialValue: ReplyBarManager(
            accountID: accountID,
            fromAddress: fromAddress,
            email: email
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            if manager.isLoadingReplies && manager.quickReplies.isEmpty && smartReplySuggestions.isEmpty {
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
            } else if !manager.quickReplies.isEmpty {
                SuggestionChipRow(
                    suggestions: manager.quickReplies,
                    icon: .appleIntelligence,
                    style: .aiGradient
                ) { suggestion in
                    let escapedHTML = "<p>\(suggestion.htmlEscaped)</p>"
                    editorState.setHTML(escapedHTML)
                    manager.replyHTML = escapedHTML
                    if !isExpanded {
                        if manager.replyTo.isEmpty { manager.replyTo = email.sender.email }
                        manager.loadExistingDraft(email: email, mailStore: mailStore, loader: onLoadDraft, editorState: editorState)
                        withAnimation(VikAnimation.springSnappy) { isExpanded = true }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !isExpanded && !smartReplySuggestions.isEmpty {
                SuggestionChipRow(suggestions: smartReplySuggestions) { suggestion in
                    if manager.replyTo.isEmpty { manager.replyTo = email.sender.email }
                    let html = "<p>\(suggestion.htmlEscaped)</p>"
                    manager.replyHTML = html
                    editorState.setHTML(html)
                    manager.loadExistingDraft(email: email, mailStore: mailStore, loader: onLoadDraft, editorState: editorState)
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
        .onChange(of: manager.replyHTML) { _, _ in
            manager.updateCachedText()
            manager.scheduleAutoSave(email: email, mailStore: mailStore)
        }
        .animation(VikAnimation.springSnappy, value: manager.hasUserContent)
        .animation(VikAnimation.springSnappy, value: NetworkMonitor.shared.isConnected)
        .animation(VikAnimation.springSnappy, value: smartReplySuggestions.isEmpty)
        .task {
            try? await Task.sleep(for: ReplyBarManager.autoSaveGuardDelay)
            manager.isInitialLoad = false
        }
        .task(id: email.id) {
            await manager.resetEmail(email: email, onGenerateQuickReplies: onGenerateQuickReplies)
        }
        .onChange(of: manager.composeVM.isSent) { _, isSent in
            guard isSent else { return }
            if !manager.composeVM.wasScheduled {
                manager.composeVM.showToast("Reply sent", type: .success)
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
            translationSourceText = manager.replyHTML.strippingHTML
            showTranslation = true
        }
        .translationPresentation(isPresented: $showTranslation, text: translationSourceText) { translated in
            guard !translated.isEmpty else { return }
            let html = translated.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "<p>\($0)</p>" }
                .joined()
            editorState.setHTML(html)
            manager.replyHTML = html
        }
        .onDisappear { manager.cancelTasks() }
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        Button {
            if manager.replyTo.isEmpty {
                manager.replyTo = email.sender.email
            }
            manager.loadExistingDraft(email: email, mailStore: mailStore, loader: onLoadDraft, editorState: editorState)
            withAnimation(VikAnimation.springSnappy) {
                isExpanded = true
            }
        } label: {
            HStack(spacing: 10) {
                Text(manager.collapsedPlaceholder(for: email, in: mailStore))
                    .font(Typography.body)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: manager.hasSavedDraft(for: email, in: mailStore) ? "arrow.uturn.forward" : "square.and.pencil")
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
            // Recipient fields
            VStack(spacing: 0) {
                AutocompleteTextField(label: "To", placeholder: "Recipients", text: $manager.replyTo, contacts: contacts)
                Divider().padding(.horizontal, Spacing.lg)

                if manager.showCc {
                    AutocompleteTextField(label: "Cc", placeholder: "Cc recipients", text: $manager.replyCc, contacts: contacts)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    Divider().padding(.horizontal, Spacing.lg)
                }

                if manager.showBcc {
                    AutocompleteTextField(label: "Bcc", placeholder: "Bcc recipients", text: $manager.replyBcc, contacts: contacts)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    Divider().padding(.horizontal, Spacing.lg)
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button { withAnimation(VikAnimation.springSnappy) { manager.showCc.toggle() } } label: {
                        Text("Cc")
                            .font(Typography.caption)
                            .foregroundStyle(manager.showCc ? .primary : .tertiary)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xs)
                            .glassEffect(manager.showCc ? .regular.interactive() : .identity, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    Button { withAnimation(VikAnimation.springSnappy) { manager.showBcc.toggle() } } label: {
                        Text("Bcc")
                            .font(Typography.caption)
                            .foregroundStyle(manager.showBcc ? .primary : .tertiary)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xs)
                            .glassEffect(manager.showBcc ? .regular.interactive() : .identity, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)

                Divider().padding(.horizontal, Spacing.lg)

                HStack(spacing: 8) {
                    Text("Subject")
                        .font(Typography.captionRegular)
                        .foregroundStyle(.tertiary)
                        .frame(width: 50, alignment: .leading)

                    if manager.showSubject {
                        TextField("Subject", text: Binding(
                            get: { manager.subjectOverride ?? email.subject.withReplyPrefix },
                            set: { manager.subjectOverride = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(Typography.captionRegular)
                        .foregroundStyle(.primary)
                    } else {
                        Text(manager.subjectOverride ?? email.subject.withReplyPrefix)
                            .font(Typography.captionRegular)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        withAnimation(VikAnimation.springSnappy) { manager.showSubject.toggle() }
                    } label: {
                        Image(systemName: manager.showSubject ? "chevron.up" : "chevron.down")
                            .font(Typography.captionSmall)
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.xs)

                Divider().padding(.horizontal, Spacing.lg)
            }
            .zIndex(10)

            WebRichTextEditor(
                state: editorState,
                htmlContent: $manager.replyHTML,
                placeholder: "Write a reply...",
                autoFocus: true,
                onFileDrop: { url in manager.handleFileDrop(url, editorState: editorState) },
                onOpenLink: onOpenLink
            )
            .frame(minHeight: 120, maxHeight: 400)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .strokeBorder(Color.accentColor.opacity(isEditorFocused ? 0.3 : 0), lineWidth: 1)
            )
            .overlay {
                if manager.isLoadingDraft {
                    ContentShimmerView()
                        .padding(Spacing.lg)
                        .transition(.opacity)
                }
            }
            .animation(VikAnimation.contentSwitch, value: manager.isLoadingDraft)
            .animation(VikAnimation.springSnappy, value: isEditorFocused)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.sm)
            .onAppear { isEditorFocused = true }
            .onDisappear { isEditorFocused = false }

            AttachmentChipRow(attachments: $manager.attachments)

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
            if let err = manager.sendError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Typography.captionRegular)
                    Text(err)
                        .font(Typography.captionRegular)
                    Spacer()
                    Button {
                        manager.sendError = nil
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
            }

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

                Button {
                    Task {
                        let urls = await manager.attachFiles()
                        manager.attachments += urls
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Attach file")

                Spacer()

                if manager.hasUserContent {
                    Button { discardAction() } label: {
                        Text("Discard")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("Discard")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))

                    ScheduleSendButton(
                        onSend: { Task { sendHapticTrigger.toggle(); await manager.sendReply(email: email, editorInlineImages: editorState.pendingInlineImages, mailStore: mailStore) } },
                        onSchedule: { date in Task { await manager.scheduleReply(at: date, email: email, editorInlineImages: editorState.pendingInlineImages, mailStore: mailStore) } },
                        isSending: manager.composeVM.isSending
                    )
                    .disabled(manager.composeVM.isSending)
                    .keyboardShortcut(.return, modifiers: .command)
                    .sensoryFeedback(.success, trigger: sendHapticTrigger)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        }
        .matchedGeometryEffect(id: "replyBar", in: replyBarNamespace)
    }

    // MARK: - Actions

    private func discardAction() {
        if manager.shouldShowDiscardAlert(email: email, mailStore: mailStore) {
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
        manager.collapse(email: email, mailStore: mailStore)
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
        nonisolated(unsafe) private var monitor: Any?

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
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
