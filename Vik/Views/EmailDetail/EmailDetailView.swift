import AppKit
import QuickLook
import SwiftUI
import Translation
import UniformTypeIdentifiers

struct EmailDetailView: View {
    let email: Email
    let accountID: String
    let actions: EmailDetailActions
    var attachmentIndexer: AttachmentIndexer?
    var allLabels: [GmailLabel]
    var fromAddress: String = ""
    var mailStore: MailStore
    var contacts: [StoredContact] = []
    private var mailDatabase: MailDatabase?

    @State private var detailVM: EmailDetailViewModel
    @State private var summaryVM = EmailSummaryViewModel()
    @State private var didUnsubscribe = false
    @State private var showOriginalInviteEmail = false
    @State private var userToggledMessageIDs: Set<String> = []
    @State private var expandedCount: Int = 0
    @State private var labelSuggestions: [LabelSuggestion] = []
    @State private var showTranslation = false
    @State private var showMetadata = false
    @State private var showConversation = false
    @State private var calendarContextDismissed = false
    @AppStorage("aiLabelSuggestions") private var aiLabelSuggestionsEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        self.mailDatabase = mailDatabase
        self._detailVM = State(initialValue: EmailDetailViewModel(accountID: accountID))
    }

    // MARK: - Derived content (delegated to ViewModel)

    private var currentLabelIDs: [String] {
        detailVM.currentLabelIDs(fallback: email.gmailLabelIDs)
    }

    /// Expansion state derived from latest message — no explicit timing needed.
    /// Latest message is expanded by default; user toggle inverts the default.
    private func isMessageExpanded(_ message: GmailMessage) -> Bool {
        let isLatest = message.id == detailVM.latestMessage?.id
        let wasToggled = userToggledMessageIDs.contains(message.id)
        return isLatest != wasToggled
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
                                .opacity(showMetadata ? 1 : 0)
                                .offset(y: showMetadata ? 0 : OffsetToken.small)

                            Divider()
                                .padding(.horizontal, Spacing.xl)
                                .opacity(showMetadata ? OpacityToken.divider : 0)

                            conversationCards
                                .overlay(alignment: .top) {
                                    if colorScheme == .dark {
                                        LinearGradient(
                                            colors: [Color(nsColor: .windowBackgroundColor).opacity(0.3), .clear],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                        .frame(height: 16)
                                        .allowsHitTesting(false)
                                    }
                                }
                                .overlay(alignment: .bottom) {
                                    if colorScheme == .dark {
                                        LinearGradient(
                                            colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.3)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                        .frame(height: 16)
                                        .allowsHitTesting(false)
                                    }
                                }
                                .opacity(showConversation ? 1 : 0)
                                .offset(y: showConversation ? 0 : OffsetToken.small)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .task(id: detailVM.latestMessage?.id) {
                        if let latestID = detailVM.latestMessage?.id {
                            userToggledMessageIDs = []
                            expandedCount = 1
                            try? await Task.sleep(for: .milliseconds(100))
                            withAnimation(reduceMotion ? nil : VikAnimation.springDefault) { proxy.scrollTo(latestID, anchor: .top) }
                        }
                    }
                    .animation(reduceMotion ? nil : VikAnimation.contentSwitch, value: email.id)
                    .safeAreaInset(edge: .bottom) {
                        ReplyBarView(
                            email: email,
                            accountID: accountID,
                            fromAddress: fromAddress,
                            mailStore: mailStore,
                            onOpenLink: actions.onOpenLink,
                            onLoadDraft: actions.onLoadDraft,
                            contacts: contacts
                        )
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.lg)
                    }
                }
            }
        }
        .task(id: email.id) {
            showMetadata = false
            showConversation = false
            calendarContextDismissed = false
            // mailDatabase MUST be set before any await — loadThread() reads it synchronously.
            detailVM.mailDatabase = mailDatabase

            if reduceMotion {
                showMetadata = true
            } else {
                withAnimation(VikAnimation.springDefault) {
                    showMetadata = true
                }
            }

            await loadThread()

            if reduceMotion {
                showConversation = true
            } else {
                withAnimation(VikAnimation.springDefault.delay(0.08)) {
                    showConversation = true
                }
            }
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
        .quickLookPreview($detailVM.quickLookSelection, in: detailVM.quickLookURLs)
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
                    .font(Typography.titleLarge)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
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
                .accessibilityLabel("More message options")
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
                .zIndex(ZIndexToken.toast)

                if !labelSuggestions.isEmpty {
                    ForEach(Array(labelSuggestions.enumerated()), id: \.element.name) { index, suggestion in
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
                            .background(Color.accentColor.opacity(OpacityToken.highlight))
                            .foregroundStyle(Color.accentColor.opacity(OpacityToken.secondary))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add label: \(suggestion.name)")
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.9))
                                .animation(reduceMotion ? nil : VikAnimation.springSnappy.delay(Double(min(index, 8)) * DurationToken.stagger))
                        )
                    }
                    .animation(reduceMotion ? nil : VikAnimation.springSnappy, value: labelSuggestions.count)
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
                    groupedTrackers: detailVM.groupedTrackers,
                    onAllow: { detailVM.allowBlockedContent() }
                )
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            if let contextEvent = detailVM.calendarContextEvent, !calendarContextDismissed {
                CalendarContextCard(
                    event: contextEvent,
                    onNavigate: {
                        actions.onNavigateToCalendar?(contextEvent)
                        calendarContextDismissed = true
                    },
                    onDismiss: {
                        withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                            calendarContextDismissed = true
                        }
                    }
                )
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let invite = detailVM.calendarInvite {
                CalendarInviteCardView(
                    invite: invite,
                    isLoading: detailVM.rsvpInProgress,
                    showOriginalEmail: $showOriginalInviteEmail,
                    calendarEvent: detailVM.matchedCalendarEvent,
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
            withAnimation(reduceMotion ? nil : VikAnimation.contentSwitch) { labelSuggestions = suggestions }
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
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if expandedCount > 1 {
                        Button {
                            withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                                userToggledMessageIDs = []
                                expandedCount = 1
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

            GlassEffectContainer(spacing: 1) {
                LazyVStack(spacing: 1, pinnedViews: []) {
                    ForEach(Array(allMessages.enumerated()), id: \.element.id) { index, message in
                        threadCard(for: message, at: index)
                            .id(message.id)
                    }
                }
            }
        }
    }

    // MARK: - Thread Card

    /// Bundles all closure-based callbacks for a single thread card, pre-built once
    /// per message to avoid creating 17 closures inside every `ForEach` iteration.
    private struct ThreadCardActions {
        let onToggle: () -> Void
        let onOpenLink: ((URL) -> Void)?
        let onPreviewAttachment: (Attachment, GmailMessagePart) -> Void
        let onDownloadAttachment: (Attachment, GmailMessagePart) -> Void
        let onOpenAttachment: (Attachment, GmailMessagePart) -> Void
        let onSaveAllAttachments: () -> Void
        let onShareAttachment: (Attachment, GmailMessagePart, NSView) -> Void
        let onDragAttachment: (Attachment, GmailMessagePart) -> NSItemProvider
        let composeTo: (String) -> Void
        let searchSender: (String) -> Void
        let onReply: (GmailMessage) -> Void
        let onReplyAll: (GmailMessage) -> Void
        let onForward: (GmailMessage) -> Void
        let onMarkUnread: (GmailMessage) -> Void
    }

    private func makeThreadCardActions(for message: GmailMessage, at index: Int) -> ThreadCardActions {
        ThreadCardActions(
            onToggle: {
                let isCurrentlyExpanded = isMessageExpanded(message)
                let isExpanding = !isCurrentlyExpanded
                let delay = isExpanding ? Double(min(index, 8)) * DurationToken.stagger : 0
                withAnimation(reduceMotion ? nil : VikAnimation.springSnappy.delay(delay)) {
                    if userToggledMessageIDs.contains(message.id) {
                        userToggledMessageIDs.remove(message.id)
                    } else {
                        userToggledMessageIDs.insert(message.id)
                    }
                    expandedCount += isCurrentlyExpanded ? -1 : 1
                }
            },
            onOpenLink: actions.onOpenLink,
            onPreviewAttachment: { attachment, part in
                Task { await detailVM.loadAndPreview(attachment: attachment, part: part, message: message) }
            },
            onDownloadAttachment: { attachment, part in
                Task {
                    guard let data = await detailVM.downloadAndSave(
                        attachment: attachment, part: part, messageID: message.id
                    ) else { return }
                    saveAttachmentData(data, named: attachment.name)
                }
            },
            onOpenAttachment: { attachment, part in
                Task { await detailVM.openAttachmentInDefaultApp(attachment, part: part, messageID: message.id) }
            },
            onSaveAllAttachments: {
                Task { await detailVM.saveAllAttachments(for: message) }
            },
            onShareAttachment: { attachment, part, anchorView in
                Task {
                    guard let url = await detailVM.prepareAttachmentTempFile(attachment, part: part, messageID: message.id) else { return }
                    let picker = NSSharingServicePicker(items: [url])
                    picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
                }
            },
            onDragAttachment: { attachment, part in
                let api = detailVM.api
                let acctID = detailVM.accountID
                let msgID = message.id
                let filename = attachment.name
                let attachID = attachment.gmailAttachmentId ?? attachment.id.uuidString
                let ext = (filename as NSString).pathExtension
                let typeID = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
                let item = NSItemProvider()
                item.suggestedName = filename
                item.registerFileRepresentation(
                    forTypeIdentifier: typeID,
                    fileOptions: [],
                    visibility: .all
                ) { completion in
                    Task {
                        do {
                            guard let gmailAttachmentID = part.body?.attachmentId else {
                                completion(nil, false, URLError(.badServerResponse))
                                return
                            }
                            let data = try await api.getAttachment(
                                messageID: msgID, attachmentID: gmailAttachmentID, accountID: acctID
                            )
                            let url = try await TemporaryFileManager.shared.tempFile(
                                for: attachID, messageID: msgID, filename: filename, data: data
                            )
                            FileUtils.setQuarantine(on: url)
                            completion(url, false, nil)
                        } catch {
                            completion(nil, false, error)
                        }
                    }
                    return Progress()
                }
                return item
            },
            composeTo: { actions.onComposeTo?($0) },
            searchSender: { actions.onSearchSender?($0) },
            onReply: { msg in
                let sub = msg.subject.withReplyPrefix
                let body = msg.htmlBody ?? msg.snippet ?? ""
                actions.onReply?(.reply(
                    to: msg.from, subject: sub, quotedBody: body,
                    replyToMessageID: msg.id, threadID: msg.threadId,
                    parentMessageID: msg.messageID, parentReferences: msg.header(named: "References")
                ))
            },
            onReplyAll: { msg in
                let sub = msg.subject.withReplyPrefix
                let body = msg.htmlBody ?? msg.snippet ?? ""
                let fields = EmailDetailViewModel.buildReplyAllFields(from: msg, selfEmail: fromAddress)
                actions.onReplyAll?(.replyAll(
                    to: fields.to, cc: fields.cc,
                    subject: sub, quotedBody: body,
                    replyToMessageID: msg.id, threadID: msg.threadId,
                    parentMessageID: msg.messageID, parentReferences: msg.header(named: "References")
                ))
            },
            onForward: { msg in
                let sub = msg.subject.withForwardPrefix
                let body = msg.htmlBody ?? msg.snippet ?? ""
                actions.onForward?(.forward(subject: sub, quotedBody: body))
            },
            onMarkUnread: { _ in actions.onMarkUnread?() }
        )
    }

    private func threadCard(for message: GmailMessage, at index: Int) -> some View {
        let isLastCard = message.id == detailVM.messages.last?.id
        let cardActions = makeThreadCardActions(for: message, at: index)
        return ThreadMessageCardView(
            message: message,
            isExpanded: isMessageExpanded(message),
            fromAddress: fromAddress,
            isLast: isLastCard,
            resolvedHTML: detailVM.resolvedMessageHTML[message.id],
            onToggle: cardActions.onToggle,
            onOpenLink: cardActions.onOpenLink,
            attachmentPairs: detailVM.attachmentPairsForMessage(message),
            onPreviewAttachment: cardActions.onPreviewAttachment,
            onDownloadAttachment: cardActions.onDownloadAttachment,
            onOpenAttachment: cardActions.onOpenAttachment,
            onSaveAllAttachments: cardActions.onSaveAllAttachments,
            onShareAttachment: cardActions.onShareAttachment,
            onDragAttachment: cardActions.onDragAttachment,
            downloadingAttachmentIDs: detailVM.downloadingAttachmentIDs,
            batchProgress: detailVM.batchDownloadProgress,
            accountID: accountID,
            composeTo: cardActions.composeTo,
            searchSender: cardActions.searchSender,
            onReply: cardActions.onReply,
            onReplyAll: cardActions.onReplyAll,
            onForward: cardActions.onForward,
            onMarkUnread: cardActions.onMarkUnread,
            precomputedHTML: detailVM.precomputedHTMLParts[message.id]
        )
        .equatable()
    }

    // MARK: - Load

    private func loadThread() async {
        guard let threadID = email.gmailThreadID else { return }
        detailVM.attachmentIndexer = attachmentIndexer
        detailVM.onMessagesRead = actions.onMessagesRead
        await detailVM.loadThread(id: threadID)
    }

    private func applyLabelSuggestion(_ suggestion: LabelSuggestion) {
        withAnimation(reduceMotion ? nil : VikAnimation.contentSwitch) { labelSuggestions.removeAll { $0.name == suggestion.name } }
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
