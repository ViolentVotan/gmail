import SwiftUI
import Translation

struct EmailDetailView: View {
    let email: Email
    let accountID: String
    let actions: EmailDetailActions
    var attachmentIndexer: AttachmentIndexer?
    var allLabels: [GmailLabel]
    var fromAddress: String = ""
    var mailStore: MailStore
    var contacts: [StoredContact] = []

    @State private var detailVM: EmailDetailViewModel
    @State private var summaryVM = EmailSummaryViewModel()
    @State private var didUnsubscribe = false
    @State private var showOriginalInviteEmail = false
    @State private var expandedMessageIDs: Set<String> = []
    @State private var labelSuggestions: [LabelSuggestion] = []
    @State private var showTranslation = false
    @AppStorage("aiLabelSuggestions") private var aiLabelSuggestionsEnabled = true

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
        mailDatabase: MailDatabase? = nil,
        contacts: [StoredContact] = []
    ) {
        self.email = email
        self.accountID = accountID
        self.mailStore = mailStore
        self.actions = actions
        self.attachmentIndexer = attachmentIndexer
        self.allLabels = allLabels
        self.fromAddress = fromAddress
        self.contacts = contacts
        let vm = EmailDetailViewModel(accountID: accountID)
        vm.mailDatabase = mailDatabase
        self._detailVM = State(initialValue: vm)
    }

    // MARK: - Derived content (delegated to ViewModel)

    private var currentLabelIDs: [String] {
        detailVM.currentLabelIDs(fallback: email.gmailLabelIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            if detailVM.isLoading && detailVM.thread == nil {
                EmailDetailSkeletonView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            threadMetadata
                            conversationCards
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .task(id: detailVM.latestMessage?.id) {
                        if let latestID = detailVM.latestMessage?.id {
                            expandedMessageIDs = [latestID]
                            try? await Task.sleep(for: .milliseconds(100))
                            withAnimation { proxy.scrollTo(latestID, anchor: .bottom) }
                        }
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
                            smartReplySuggestions: detailVM.smartReplySuggestions,
                            onSmartReplySelect: { suggestion in
                                let sub = email.subject.withReplyPrefix
                                let body = "<p>\(suggestion.htmlEscaped)</p>"
                                let mode = ComposeMode.reply(
                                    to: email.sender.email,
                                    subject: sub,
                                    quotedBody: body,
                                    replyToMessageID: email.gmailMessageID ?? "",
                                    threadID: email.gmailThreadID ?? ""
                                )
                                actions.onReply?(mode)
                            },
                            contacts: contacts
                        )
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.lg)
                        .task(id: email.id) {
                            detailVM.loadSmartReplies(for: email)
                        }
                    }
                }
            }
        }
        .task(id: email.id) {
            await loadThread()
        }
        .userActivity(UserActivityManager.viewEmailActivityType) { activity in
            let source = UserActivityManager.activity(for: email, accountID: accountID)
            activity.title = source.title
            activity.isEligibleForSearch = true
            activity.isEligibleForHandoff = false
            activity.targetContentIdentifier = source.targetContentIdentifier
            activity.contentAttributeSet = source.contentAttributeSet
            activity.userInfo = source.userInfo
        }
        .translationPresentation(
            isPresented: $showTranslation,
            text: detailVM.latestMessage?.plainBody ?? email.body
        )
    }

    // MARK: - Thread Metadata

    private var threadMetadata: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(detailVM.latestMessage?.subject ?? email.subject)
                    .font(Typography.title)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Menu {
                    if isMailingList, let url = resolvedUnsubscribeURL, !alreadyUnsubscribed {
                        Button(role: .destructive) {
                            Task {
                                let msgID = email.gmailMessageID
                                let success = await actions.onUnsubscribe?(url, oneClick, msgID) ?? false
                                if success { didUnsubscribe = true }
                            }
                        } label: {
                            Label("Unsubscribe", systemImage: "xmark.circle")
                        }

                        Divider()
                    }

                    Button {
                        showTranslation = true
                    } label: {
                        Label("Translate", systemImage: "translate")
                    }

                    Button {
                        guard let msg = detailVM.latestMessage else { return }
                        actions.onDownloadMessage?(msg, detailVM.accountID)
                    } label: {
                        Label("Download Message", systemImage: "arrow.down.circle")
                    }
                    Button {
                        guard let msg = detailVM.latestMessage else { return }
                        actions.onShowOriginal?(msg, detailVM.accountID)
                    } label: {
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
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.sm)

            HStack(spacing: 6) {
                LabelEditorView(
                    currentLabelIDs: currentLabelIDs,
                    allLabels: allLabels,
                    detailVM: detailVM,
                    onAddLabel: actions.onAddLabel,
                    onRemoveLabel: actions.onRemoveLabel,
                    onCreateAndAddLabel: actions.onCreateAndAddLabel
                )
                .zIndex(1)

                if !labelSuggestions.isEmpty {
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
                    .animation(SerifAnimation.springSnappy, value: labelSuggestions.map(\.name))
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.md)

            #if canImport(FoundationModels)
            InsightCardView(insight: summaryVM.insight)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
                .task(id: email.id) {
                    summaryVM.cancelStreaming()
                    summaryVM.startStreaming(for: email)
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

    // MARK: - Conversation Cards

    private var conversationCards: some View {
        VStack(alignment: .leading, spacing: 0) {
            let allMessages = detailVM.messages
            if allMessages.count > 1 {
                HStack {
                    Text("\(allMessages.count) messages")
                        .font(Typography.captionRegular)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("\(allMessages.count) messages in thread")
                    Spacer()
                    if expandedMessageIDs.count > 1 {
                        Button {
                            withAnimation(SerifAnimation.springSnappy) {
                                if let latestID = detailVM.latestMessage?.id {
                                    expandedMessageIDs = [latestID]
                                }
                            }
                        } label: {
                            Text("Collapse Others")
                                .font(Typography.captionRegular)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Collapse other messages")
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.sm)
            }

            LazyVStack(spacing: 1) {
                ForEach(allMessages, id: \.id) { message in
                    let isLastCard = message.id == allMessages.last?.id
                    ThreadMessageCardView(
                        message: message,
                        isExpanded: expandedMessageIDs.contains(message.id),
                        fromAddress: fromAddress,
                        isLast: isLastCard,
                        resolvedHTML: detailVM.resolvedMessageHTML[message.id],
                        onToggle: {
                            withAnimation(SerifAnimation.springSnappy) {
                                if expandedMessageIDs.contains(message.id) {
                                    expandedMessageIDs.remove(message.id)
                                } else {
                                    expandedMessageIDs.insert(message.id)
                                }
                            }
                        },
                        onOpenLink: actions.onOpenLink,
                        attachmentPairs: detailVM.attachmentPairsForMessage(message),
                        onPreviewAttachment: { attachment, part in
                            Task {
                                await detailVM.loadAndPreview(
                                    attachment: attachment,
                                    part: part,
                                    messageID: message.id,
                                    onPreviewAttachment: actions.onPreviewAttachment
                                )
                            }
                        },
                        onDownloadAttachment: { attachment, part in
                            Task {
                                guard let data = await detailVM.downloadAndSave(
                                    attachment: attachment,
                                    part: part,
                                    messageID: message.id
                                ) else { return }
                                saveAttachmentData(data, named: attachment.name)
                            }
                        }
                    )
                    .id(message.id)
                }
            }
        }
    }

    // MARK: - Load

    private func loadThread() async {
        guard let threadID = email.gmailThreadID else { return }
        detailVM.attachmentIndexer = attachmentIndexer
        detailVM.onMessagesRead = actions.onMessagesRead
        await detailVM.loadThread(id: threadID)
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

    /// Thin view-layer wrapper -- NSSavePanel must run on the main thread.
    private func saveAttachmentData(_ data: Data, named name: String) {
        FileUtils.saveWithPanel(data: data, suggestedName: name)
    }
}
