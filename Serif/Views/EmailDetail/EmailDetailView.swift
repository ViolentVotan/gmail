import SwiftUI

struct EmailDetailView: View {
    let email: Email
    let accountID: String
    let actions: EmailDetailActions
    var attachmentIndexer: AttachmentIndexer?
    var allLabels: [GmailLabel]
    var fromAddress: String = ""
    var mailStore: MailStore

    @State private var detailVM: EmailDetailViewModel
    @State private var emailBodyHeight: CGFloat = 100
    @State private var didUnsubscribe = false
    @State private var showSenderInfo = false
    @State private var showOriginalInviteEmail = false
    @State private var showQuotedMain = false
    @State private var cachedMainHTMLParts: (original: String, quoted: String?)?
    @State private var cachedMainHTMLSource: String?
    @State private var labelSuggestions: [LabelSuggestion] = []
    @AppStorage("aiLabelSuggestions") private var aiLabelSuggestionsEnabled = true
    @ScaledMetric(relativeTo: .body) private var senderAvatarSize: CGFloat = 40

    /// Best available unsubscribe URL: header-based (from full thread) or body-scanned.
    private var resolvedUnsubscribeURL: URL? {
        if let url = detailVM.latestMessage?.unsubscribeURL { return url }
        if let html = detailVM.latestMessage?.htmlBody ?? detailVM.latestMessage?.plainBody,
           let url = actions.extractBodyUnsubscribeURL?(html) { return url }
        return email.unsubscribeURL
    }

    private var isMailingList: Bool {
        detailVM.latestMessage?.isFromMailingList ?? email.isFromMailingList || resolvedUnsubscribeURL != nil
    }

    private var oneClick: Bool {
        detailVM.latestMessage?.supportsOneClickUnsubscribe ?? false
    }

    private var alreadyUnsubscribed: Bool {
        if didUnsubscribe { return true }
        guard let msgID = email.gmailMessageID else { return false }
        return actions.checkUnsubscribed?(msgID) ?? false
    }

    init(
        email: Email,
        accountID: String,
        mailStore: MailStore,
        actions: EmailDetailActions = EmailDetailActions(),
        attachmentIndexer: AttachmentIndexer? = nil,
        allLabels: [GmailLabel] = [],
        fromAddress: String = "",
        mailDatabase: MailDatabase? = nil
    ) {
        self.email = email
        self.accountID = accountID
        self.mailStore = mailStore
        self.actions = actions
        self.attachmentIndexer = attachmentIndexer
        self.allLabels = allLabels
        self.fromAddress = fromAddress
        let vm = EmailDetailViewModel(accountID: accountID)
        vm.mailDatabase = mailDatabase
        self.detailVM = vm
    }

    // MARK: - Derived content (delegated to ViewModel)

    private var displayAttachments: [Attachment] {
        detailVM.displayAttachments(fallback: email.attachments)
    }

    private var olderThreadMessages: [GmailMessage] {
        detailVM.olderThreadMessages
    }

    private var currentLabelIDs: [String] {
        detailVM.currentLabelIDs(fallback: email.gmailLabelIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            if detailVM.isLoading && detailVM.thread == nil {
                EmailDetailSkeletonView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        senderHeader
                            .padding(.horizontal, Spacing.xl)
                            .padding(.top, Spacing.xl)
                            .padding(.bottom, Spacing.lg)

                        HStack(alignment: .top) {
                            Text(detailVM.latestMessage?.subject ?? email.subject)
                                .font(Typography.title)
                                .foregroundStyle(.primary)

                            Spacer()

                            Menu {
                                Button { actions.onDownloadMessage?(detailVM) } label: {
                                    Label("Download Message", systemImage: "arrow.down.circle")
                                }
                                Button { actions.onShowOriginal?(detailVM) } label: {
                                    Label("Show Original", systemImage: "doc.text")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(Typography.body)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: ButtonSize.lg, height: ButtonSize.lg)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Message options")
                        }
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.md)

                        LabelEditorView(
                            currentLabelIDs: currentLabelIDs,
                            allLabels: allLabels,
                            detailVM: detailVM,
                            onAddLabel: actions.onAddLabel,
                            onRemoveLabel: actions.onRemoveLabel,
                            onCreateAndAddLabel: actions.onCreateAndAddLabel
                        )
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, labelSuggestions.isEmpty ? Spacing.xl : 6)
                        .zIndex(1)

                        if !labelSuggestions.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(labelSuggestions, id: \.name) { suggestion in
                                    Button {
                                        applyLabelSuggestion(suggestion)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: suggestion.isNew ? "plus.circle" : "plus")
                                                .font(Typography.captionSmall)
                                            Text(suggestion.name)
                                                .font(Typography.captionSmallRegular)
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.08))
                                        .foregroundStyle(Color.accentColor.opacity(0.7))
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                }
                            }
                            .padding(.horizontal, Spacing.xl)
                            .padding(.bottom, Spacing.lg)
                            .animation(SerifAnimation.springSnappy, value: labelSuggestions.map(\.name))
                        }

                        #if canImport(FoundationModels)
                        if #available(macOS 26.0, *) {
                            InsightCardView(email: email)
                                .padding(.horizontal, Spacing.xl)
                                .padding(.bottom, Spacing.md)
                        }
                        #endif

                        if detailVM.hasBlockedTrackers {
                            TrackerBannerView(
                                trackerCount: detailVM.blockedTrackerCount,
                                trackers: detailVM.trackerResult?.trackers ?? [],
                                onAllow: { detailVM.allowBlockedContent() }
                            )
                            .padding(.horizontal, Spacing.xl)
                            .padding(.bottom, Spacing.md)
                        }

                        if let invite = detailVM.calendarInvite {
                            CalendarInviteCardView(
                                invite: invite,
                                isLoading: detailVM.rsvpInProgress,
                                showOriginalEmail: $showOriginalInviteEmail,
                                onAccept:  { Task { await detailVM.sendRSVP(.accepted) } },
                                onDecline: { Task { await detailVM.sendRSVP(.declined) } },
                                onMaybe:   { Task { await detailVM.sendRSVP(.maybe) } }
                            )
                            .padding(.horizontal, Spacing.xl)
                            .padding(.bottom, Spacing.md)
                        }

                        // Latest message: full HTML rendering with quote stripping
                        if detailVM.calendarInvite == nil || showOriginalInviteEmail {
                            let rawHTML = detailVM.resolvedHTML ?? detailVM.displayHTML ?? detailVM.latestMessage?.htmlBody ?? ""
                            let fullHTML = rawHTML.isEmpty
                                ? "<p>\(detailVM.latestMessage?.plainBody ?? email.body)</p>"
                                : rawHTML
                            let parts = mainHTMLParts(for: fullHTML)
                            let htmlToRender = (showQuotedMain || parts.quoted == nil) ? fullHTML : parts.original

                            HTMLEmailView(html: htmlToRender, contentHeight: $emailBodyHeight, onOpenLink: actions.onOpenLink)
                                .frame(height: emailBodyHeight)
                                .padding(.horizontal, Spacing.xl)
                                .padding(.bottom, parts.quoted != nil ? Spacing.xs : Spacing.xl)
                                .accessibilityLabel("Email from \(email.sender.name): \(email.subject)")

                            if parts.quoted != nil {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showQuotedMain.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: showQuotedMain ? "chevron.up" : "chevron.down")
                                            .font(Typography.captionSmall)
                                        Text(showQuotedMain ? "Hide quoted text" : "Show quoted text")
                                            .font(Typography.captionRegular)
                                    }
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, Spacing.xs)
                                    .background(Capsule().fill(.quaternary))
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, Spacing.xl)
                                .padding(.bottom, Spacing.xl)
                            }
                        }

                        if !displayAttachments.isEmpty {
                            attachmentsSection
                                .padding(.horizontal, Spacing.xl)
                                .padding(.bottom, Spacing.xl)
                        }

                        // Older thread messages as chat bubbles
                        if !olderThreadMessages.isEmpty {
                            conversationSection
                                .padding(.horizontal, Spacing.xl)
                                .padding(.bottom, Spacing.md)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                }
                .task(id: email.id) {
                    labelSuggestions = []
                    guard aiLabelSuggestionsEnabled else { return }
                    let suggestions = await detailVM.generateLabelSuggestions(
                        for: email,
                        existingLabels: allLabels
                    )
                    withAnimation { labelSuggestions = suggestions }
                }
                .contentTransition(.opacity)
                .animation(SerifAnimation.springSnappy, value: email.id)
                .safeAreaInset(edge: .bottom) {
                    ReplyBarView(
                        email: email,
                        accountID: accountID,
                        fromAddress: fromAddress,
                        mailStore: mailStore,
                        onOpenLink: actions.onOpenLink,
                        onGenerateQuickReplies: { [detailVM] email in
                            await detailVM.generateQuickReplies(for: email)
                        },
                        onLoadDraft: actions.onLoadDraft,
                        smartReplySuggestions: detailVM.smartReplySuggestions
                    )
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.lg)
                    .task(id: email.id) {
                        detailVM.loadSmartReplies(for: email)
                    }
                }
            }
        }
        .task(id: email.id) {
            await loadThread()
        }
    }

    // MARK: - Compose helpers (delegated to ViewModel)

    private func replyMode() -> ComposeMode {
        detailVM.replyMode(email: email)
    }

    private func replyAllMode() -> ComposeMode {
        detailVM.replyAllMode(email: email)
    }

    private func forwardMode() -> ComposeMode {
        detailVM.forwardMode(email: email)
    }

    // MARK: - Load

    private func loadThread() async {
        guard let threadID = email.gmailThreadID else { return }
        detailVM.attachmentIndexer = attachmentIndexer
        detailVM.onMessagesRead = actions.onMessagesRead
        await detailVM.loadThread(id: threadID)
    }

    /// Returns cached quote-stripped parts for the latest message HTML, recomputing only when the source changes.
    private func mainHTMLParts(for html: String) -> (original: String, quoted: String?) {
        if html == cachedMainHTMLSource, let cached = cachedMainHTMLParts {
            return cached
        }
        let parts = GmailThreadMessageView.stripQuotedHTML(html)
        cachedMainHTMLSource = html
        cachedMainHTMLParts = parts
        return parts
    }

    private func applyLabelSuggestion(_ suggestion: LabelSuggestion) {
        withAnimation { labelSuggestions.removeAll { $0.name == suggestion.name } }
        detailVM.applyLabelSuggestion(
            suggestion,
            allLabels: allLabels,
            fallbackLabelIDs: email.gmailLabelIDs,
            onCreateAndAddLabel: actions.onCreateAndAddLabel,
            onAddLabel: actions.onAddLabel
        )
    }

    // MARK: - Attachment preview & download (delegated to ViewModel)

    private func loadAndPreview(attachment: Attachment, part: GmailMessagePart) {
        Task {
            await detailVM.loadAndPreview(
                attachment: attachment,
                part: part,
                onPreviewAttachment: actions.onPreviewAttachment
            )
        }
    }

    private func downloadAttachment(attachment: Attachment, part: GmailMessagePart) {
        Task {
            guard let data = await detailVM.downloadAndSave(attachment: attachment, part: part) else { return }
            saveAttachmentData(data, named: attachment.name)
        }
    }

    /// Thin view-layer wrapper -- NSSavePanel must run on the main thread.
    private func saveAttachmentData(_ data: Data, named name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    // MARK: - Sender Header

    private var senderHeader: some View {
        HStack(spacing: 12) {
            AvatarView(
                initials: email.sender.initials,
                color:    email.sender.avatarColor,
                size:     senderAvatarSize,
                avatarURL: email.sender.avatarURL,
                senderDomain: email.sender.domain
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(email.sender.name)
                    .font(Typography.calloutSemibold)
                    .foregroundStyle(.primary)

                Text(email.sender.email)
                    .font(Typography.subheadRegular)
                    .foregroundStyle(.tertiary)
                    .underline(showSenderInfo, color: .gray)
                    .onHover { hovering in
                        showSenderInfo = hovering
                    }
                    .popover(isPresented: $showSenderInfo, arrowEdge: .bottom) {
                        if let msg = detailVM.latestMessage {
                            SenderInfoPopover(message: msg, email: email)
                        }
                    }
            }

            Spacer()

            Text(email.date.formattedFull)
                .font(Typography.subheadRegular)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Attachments

    private var attachmentPairs: [(Attachment, GmailMessagePart?)] {
        detailVM.attachmentPairs(fallback: email.attachments)
    }

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .font(Typography.subheadRegular)
                Text("\(displayAttachments.count) Attachment\(displayAttachments.count > 1 ? "s" : "")")
                    .font(Typography.subhead)
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(attachmentPairs, id: \.0.id) { (attachment, part) in
                    AttachmentChipView(
                        attachment: attachment,
                        onPreview: part.map { p in { loadAndPreview(attachment: attachment, part: p) } },
                        onDownload: part.map { p in { downloadAttachment(attachment: attachment, part: p) } }
                    )
                    .accessibilityLabel("Attachment: \(attachment.name), \(attachment.size)")
                }
            }
        }
    }

    // MARK: - Conversation (older thread messages as chat bubbles)

    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
                .background(Color(.separatorColor))

            LazyVStack(spacing: 14) {
                ForEach(olderThreadMessages, id: \.id) { message in
                    GmailThreadMessageView(
                        message: message,
                        fromAddress: fromAddress,
                        resolvedHTML: detailVM.resolvedMessageHTML[message.id],
                        onOpenLink: actions.onOpenLink
                    )
                }
            }
        }
    }
}
