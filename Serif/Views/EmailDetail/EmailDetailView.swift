import SwiftUI

struct EmailDetailView: View {
    let email: Email
    let accountID: String
    var attachmentIndexer: AttachmentIndexer?
    var onArchive:            (() -> Void)?
    var onDelete:             (() -> Void)?
    var onMoveToInbox:        (() -> Void)?
    var onDeletePermanently:  (() -> Void)?
    var onMarkNotSpam:        (() -> Void)?
    var onToggleStar:         ((Bool) -> Void)?
    var onMarkUnread:         (() -> Void)?
    var allLabels:     [GmailLabel]
    var onAddLabel:    ((String) -> Void)?
    var onRemoveLabel: ((String) -> Void)?
    var onReply:       ((ComposeMode) -> Void)?
    var onReplyAll:    ((ComposeMode) -> Void)?
    var onForward:     ((ComposeMode) -> Void)?

    var onCreateAndAddLabel: ((String, @escaping (String?) -> Void) -> Void)?
    var onPreviewAttachment: ((Data?, String, Attachment.FileType) -> Void)?
    var onShowOriginal: ((EmailDetailViewModel) -> Void)?
    var onDownloadMessage: ((EmailDetailViewModel) -> Void)?
    var onUnsubscribe: ((URL, Bool, String?) async -> Bool)?
    var onPrint: ((GmailMessage, Email) -> Void)?
    var checkUnsubscribed: ((String) -> Bool)?
    var extractBodyUnsubscribeURL: ((String) -> URL?)?
    var onOpenLink: ((URL) -> Void)?
    var onMessagesRead: (([String]) -> Void)?
    var onLoadDraft: ((String, String) async throws -> GmailDraft?)?
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

    /// Best available unsubscribe URL: header-based (from full thread) or body-scanned.
    private var resolvedUnsubscribeURL: URL? {
        if let url = detailVM.latestMessage?.unsubscribeURL { return url }
        if let html = detailVM.latestMessage?.htmlBody ?? detailVM.latestMessage?.plainBody,
           let url = extractBodyUnsubscribeURL?(html) { return url }
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
        return checkUnsubscribed?(msgID) ?? false
    }

    init(
        email: Email,
        accountID: String,
        mailStore: MailStore,
        attachmentIndexer: AttachmentIndexer? = nil,
        onArchive:            (() -> Void)? = nil,
        onDelete:             (() -> Void)? = nil,
        onMoveToInbox:        (() -> Void)? = nil,
        onDeletePermanently:  (() -> Void)? = nil,
        onMarkNotSpam:        (() -> Void)? = nil,
        onToggleStar:         ((Bool) -> Void)? = nil,
        onMarkUnread:         (() -> Void)? = nil,
        allLabels:             [GmailLabel] = [],
        onAddLabel:            ((String) -> Void)? = nil,
        onRemoveLabel:         ((String) -> Void)? = nil,
        onReply:               ((ComposeMode) -> Void)? = nil,
        onReplyAll:            ((ComposeMode) -> Void)? = nil,
        onForward:             ((ComposeMode) -> Void)? = nil,
        onCreateAndAddLabel:   ((String, @escaping (String?) -> Void) -> Void)? = nil,
        onPreviewAttachment:   ((Data?, String, Attachment.FileType) -> Void)? = nil,
        onShowOriginal:        ((EmailDetailViewModel) -> Void)? = nil,
        onDownloadMessage:     ((EmailDetailViewModel) -> Void)? = nil,
        onUnsubscribe:         ((URL, Bool, String?) async -> Bool)? = nil,
        onPrint:               ((GmailMessage, Email) -> Void)? = nil,
        checkUnsubscribed:     ((String) -> Bool)? = nil,
        extractBodyUnsubscribeURL: ((String) -> URL?)? = nil,
        fromAddress:           String = ""
    ) {
        self.email              = email
        self.accountID          = accountID
        self.mailStore          = mailStore
        self.attachmentIndexer  = attachmentIndexer
        self.onArchive          = onArchive
        self.onDelete           = onDelete
        self.onMoveToInbox      = onMoveToInbox
        self.onDeletePermanently = onDeletePermanently
        self.onMarkNotSpam      = onMarkNotSpam
        self.onToggleStar       = onToggleStar
        self.onMarkUnread       = onMarkUnread
        self.allLabels    = allLabels
        self.onAddLabel   = onAddLabel
        self.onRemoveLabel = onRemoveLabel
        self.onReply               = onReply
        self.onReplyAll            = onReplyAll
        self.onForward             = onForward
        self.onCreateAndAddLabel   = onCreateAndAddLabel
        self.onPreviewAttachment   = onPreviewAttachment
        self.onShowOriginal        = onShowOriginal
        self.onDownloadMessage     = onDownloadMessage
        self.onUnsubscribe         = onUnsubscribe
        self.onPrint               = onPrint
        self.checkUnsubscribed     = checkUnsubscribed
        self.extractBodyUnsubscribeURL = extractBodyUnsubscribeURL
        self.fromAddress           = fromAddress
        self.detailVM              = EmailDetailViewModel(accountID: accountID)
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
            DetailToolbarView(
                email: email,
                detailVM: detailVM,
                isMailingList: isMailingList,
                resolvedUnsubscribeURL: resolvedUnsubscribeURL,
                oneClick: oneClick,
                alreadyUnsubscribed: alreadyUnsubscribed,
                onArchive: onArchive,
                onDelete: onDelete,
                onMoveToInbox: onMoveToInbox,
                onDeletePermanently: onDeletePermanently,
                onMarkNotSpam: onMarkNotSpam,
                onToggleStar: onToggleStar,
                onMarkUnread: onMarkUnread,
                onReply: onReply,
                onReplyAll: onReplyAll,
                onForward: onForward,
                onShowOriginal: onShowOriginal,
                onDownloadMessage: onDownloadMessage,
                onUnsubscribe: onUnsubscribe,
                onPrint: onPrint,
                replyMode: replyMode,
                replyAllMode: replyAllMode,
                forwardMode: forwardMode,
                didUnsubscribe: $didUnsubscribe
            )

            Divider()
                .background(Color(.separatorColor))

            ZStack(alignment: .bottom) {
                if detailVM.isLoading && detailVM.thread == nil {
                    EmailDetailSkeletonView()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            senderHeader
                                .padding(.horizontal, 24)
                                .padding(.top, 24)
                                .padding(.bottom, 16)

                            Text(detailVM.latestMessage?.subject ?? email.subject)
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 10)

                            LabelEditorView(
                                currentLabelIDs: currentLabelIDs,
                                allLabels: allLabels,
                                detailVM: detailVM,
                                onAddLabel: onAddLabel,
                                onRemoveLabel: onRemoveLabel,
                                onCreateAndAddLabel: onCreateAndAddLabel
                            )
                            .padding(.horizontal, 24)
                            .padding(.bottom, labelSuggestions.isEmpty ? 20 : 6)
                            .zIndex(1)

                            if !labelSuggestions.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(labelSuggestions, id: \.name) { suggestion in
                                        Button {
                                            applyLabelSuggestion(suggestion)
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: suggestion.isNew ? "plus.circle" : "plus")
                                                    .font(.caption2.weight(.semibold))
                                                Text(suggestion.name)
                                                    .font(.caption2)
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
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                                .animation(.easeOut(duration: 0.25), value: labelSuggestions.map(\.name))
                            }

                            if detailVM.hasBlockedTrackers {
                                TrackerBannerView(
                                    trackerCount: detailVM.blockedTrackerCount,
                                    onAllow: { detailVM.allowBlockedContent() }
                                )
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
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
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                            }

                            // Latest message: full HTML rendering with quote stripping
                            if detailVM.calendarInvite == nil || showOriginalInviteEmail {
                                let rawHTML = detailVM.resolvedHTML ?? detailVM.displayHTML ?? detailVM.latestMessage?.htmlBody ?? ""
                                let fullHTML = rawHTML.isEmpty
                                    ? "<p>\(detailVM.latestMessage?.plainBody ?? email.body)</p>"
                                    : rawHTML
                                let parts = mainHTMLParts(for: fullHTML)
                                let htmlToRender = (showQuotedMain || parts.quoted == nil) ? fullHTML : parts.original

                                HTMLEmailView(html: htmlToRender, contentHeight: $emailBodyHeight, onOpenLink: onOpenLink)
                                    .frame(height: emailBodyHeight)
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, parts.quoted != nil ? 4 : 20)

                                if parts.quoted != nil {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            showQuotedMain.toggle()
                                        }
                                    } label: {
                                        Text(showQuotedMain ? "Hide quoted" : "···")
                                            .font(showQuotedMain ? .caption.weight(.medium) : .callout.bold())
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(Capsule().fill(.quaternary))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 20)
                                }
                            }

                            if !displayAttachments.isEmpty {
                                attachmentsSection
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 20)
                            }

                            // Older thread messages as chat bubbles
                            if !olderThreadMessages.isEmpty {
                                conversationSection
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 12)
                            }
                        }
                        .padding(.bottom, 72)
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
                }

                // Floating reply bar
                ReplyBarView(
                    email: email,
                    accountID: accountID,
                    fromAddress: fromAddress,
                    mailStore: mailStore,
                    onOpenLink: onOpenLink,
                    onGenerateQuickReplies: { [detailVM] email in
                        await detailVM.generateQuickReplies(for: email)
                    },
                    onLoadDraft: onLoadDraft,
                    smartReplySuggestions: detailVM.smartReplySuggestions
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .task(id: email.id) {
                        detailVM.loadSmartReplies(for: email)
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
        detailVM.onMessagesRead = onMessagesRead
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
            onCreateAndAddLabel: onCreateAndAddLabel,
            onAddLabel: onAddLabel
        )
    }

    // MARK: - Attachment preview & download (delegated to ViewModel)

    private func loadAndPreview(attachment: Attachment, part: GmailMessagePart) {
        Task {
            await detailVM.loadAndPreview(
                attachment: attachment,
                part: part,
                onPreviewAttachment: onPreviewAttachment
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
                size:     40,
                avatarURL: email.sender.avatarURL,
                senderDomain: email.sender.domain
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(email.sender.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(email.sender.email)
                    .font(.subheadline)
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
                .font(.subheadline)
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
                    .font(.subheadline)
                Text("\(displayAttachments.count) Attachment\(displayAttachments.count > 1 ? "s" : "")")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(attachmentPairs, id: \.0.id) { (attachment, part) in
                    AttachmentChipView(
                        attachment: attachment,
                        onPreview: part.map { p in { loadAndPreview(attachment: attachment, part: p) } },
                        onDownload: part.map { p in { downloadAttachment(attachment: attachment, part: p) } }
                    )
                }
            }
        }
    }

    // MARK: - Conversation (older thread messages as chat bubbles)

    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
                .background(Color(.separatorColor))

            LazyVStack(spacing: 12) {
                ForEach(olderThreadMessages, id: \.id) { message in
                    GmailThreadMessageView(
                        message: message,
                        fromAddress: fromAddress,
                        resolvedHTML: detailVM.resolvedMessageHTML[message.id],
                        onOpenLink: onOpenLink
                    )
                }
            }
        }
    }
}
