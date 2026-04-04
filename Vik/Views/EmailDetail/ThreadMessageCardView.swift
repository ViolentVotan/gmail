import SwiftUI
import AppKit

/// Equatable compares only value-type fields — closure properties (onToggle, onOpenLink, etc.)
/// are excluded because closures cannot conform to Equatable.
struct ThreadMessageCardView: View, Equatable {
    static func == (lhs: ThreadMessageCardView, rhs: ThreadMessageCardView) -> Bool {
        lhs.message.id == rhs.message.id &&
        lhs.fromAddress == rhs.fromAddress &&
        lhs.resolvedHTML == rhs.resolvedHTML &&
        lhs.isExpanded == rhs.isExpanded &&
        lhs.isLast == rhs.isLast &&
        lhs.accountID == rhs.accountID &&
        lhs.downloadingAttachmentIDs == rhs.downloadingAttachmentIDs
    }

    let message: GmailMessage
    let isExpanded: Bool
    let fromAddress: String
    let isLast: Bool
    let resolvedHTML: String?
    var onToggle: () -> Void
    var onOpenLink: ((URL) -> Void)?
    var attachmentPairs: [(Attachment, GmailMessagePart?)] = []
    var onPreviewAttachment: ((Attachment, GmailMessagePart) -> Void)?
    var onDownloadAttachment: ((Attachment, GmailMessagePart) -> Void)?
    var onOpenAttachment: ((Attachment, GmailMessagePart) -> Void)?
    var onSaveAllAttachments: (() -> Void)?
    var onShareAttachment: ((Attachment, GmailMessagePart, NSView) -> Void)?
    var onDragAttachment: ((Attachment, GmailMessagePart) -> NSItemProvider)?
    var downloadingAttachmentIDs: Set<String> = []
    var batchProgress: EmailDetailViewModel.BatchProgress?
    var accountID: String = ""
    var composeTo: ((String) -> Void)?
    var searchSender: ((String) -> Void)?
    var onReply: ((GmailMessage) -> Void)?
    var onReplyAll: ((GmailMessage) -> Void)?
    var onForward: ((GmailMessage) -> Void)?
    var onMarkUnread: ((GmailMessage) -> Void)?
    var precomputedHTML: PrecomputedMessageHTML?

    @State private var showQuoted = false
    @State private var contentHeight: CGFloat = 60
    @State private var isHTMLLoaded = false
    @State private var isHovering = false
    @State private var allowRemoteImages = false
    @AppStorage(UserDefaultsKey.alwaysLoadRemoteImages) private var alwaysLoadRemoteImages = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sender: Contact
    private let toContact: Contact
    private let isSentByMe: Bool
    private let cachedFullHTML: String
    private let cachedHTMLParts: (original: String, quoted: String?)
    private let cachedRecipientsLine: String
    private let cachedFormattedDate: String?
    private let cachedHasRemoteImages: Bool
    private let cachedCollapsedAttachmentSummary: String

    init(
        message: GmailMessage,
        isExpanded: Bool,
        fromAddress: String,
        isLast: Bool = false,
        resolvedHTML: String? = nil,
        onToggle: @escaping () -> Void,
        onOpenLink: ((URL) -> Void)? = nil,
        attachmentPairs: [(Attachment, GmailMessagePart?)] = [],
        onPreviewAttachment: ((Attachment, GmailMessagePart) -> Void)? = nil,
        onDownloadAttachment: ((Attachment, GmailMessagePart) -> Void)? = nil,
        onOpenAttachment: ((Attachment, GmailMessagePart) -> Void)? = nil,
        onSaveAllAttachments: (() -> Void)? = nil,
        onShareAttachment: ((Attachment, GmailMessagePart, NSView) -> Void)? = nil,
        onDragAttachment: ((Attachment, GmailMessagePart) -> NSItemProvider)? = nil,
        downloadingAttachmentIDs: Set<String> = [],
        batchProgress: EmailDetailViewModel.BatchProgress? = nil,
        accountID: String = "",
        composeTo: ((String) -> Void)? = nil,
        searchSender: ((String) -> Void)? = nil,
        onReply: ((GmailMessage) -> Void)? = nil,
        onReplyAll: ((GmailMessage) -> Void)? = nil,
        onForward: ((GmailMessage) -> Void)? = nil,
        onMarkUnread: ((GmailMessage) -> Void)? = nil,
        precomputedHTML: PrecomputedMessageHTML? = nil
    ) {
        self.message = message
        self.isExpanded = isExpanded
        self.fromAddress = fromAddress
        self.isLast = isLast
        self.resolvedHTML = resolvedHTML
        self.onToggle = onToggle
        self.onOpenLink = onOpenLink
        self.attachmentPairs = attachmentPairs
        self.onPreviewAttachment = onPreviewAttachment
        self.onDownloadAttachment = onDownloadAttachment
        self.onOpenAttachment = onOpenAttachment
        self.onSaveAllAttachments = onSaveAllAttachments
        self.onShareAttachment = onShareAttachment
        self.onDragAttachment = onDragAttachment
        self.downloadingAttachmentIDs = downloadingAttachmentIDs
        self.batchProgress = batchProgress
        self.accountID = accountID
        self.composeTo = composeTo
        self.searchSender = searchSender
        self.onReply = onReply
        self.onReplyAll = onReplyAll
        self.onForward = onForward
        self.onMarkUnread = onMarkUnread
        self.precomputedHTML = precomputedHTML

        let parsedSender = GmailDataTransformer.parseContact(message.from)
        self.sender = parsedSender
        self.toContact = GmailDataTransformer.parseContact(message.to)
        self.isSentByMe = !fromAddress.isEmpty && parsedSender.email.lowercased() == fromAddress.lowercased()

        if let precomputed = precomputedHTML {
            self.cachedFullHTML = precomputed.fullHTML
            self.cachedHTMLParts = (original: precomputed.originalHTML, quoted: precomputed.quotedHTML)
        } else {
            let html = GmailThreadMessageView.computeFullHTML(message: message, resolvedHTML: resolvedHTML)
            self.cachedFullHTML = html
            self.cachedHTMLParts = GmailThreadMessageView.stripQuotedHTML(html)
        }

        let parts = message.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty {
            self.cachedRecipientsLine = parsedSender.email
        } else {
            let senderEmail = parsedSender.email
            let displayParts = parts.prefix(2).map { part -> String in
                let candidateEmail: String
                if let lt = part.firstIndex(of: "<"), let gt = part.lastIndex(of: ">"), lt < gt {
                    candidateEmail = String(part[part.index(after: lt)..<gt])
                } else {
                    candidateEmail = part
                }
                if candidateEmail.lowercased() == fromAddress.lowercased() { return "me" }
                if let angleBracket = part.firstIndex(of: "<") {
                    return String(part[part.startIndex..<angleBracket]).trimmingCharacters(in: .whitespaces)
                }
                return part
            }
            let remaining = max(0, parts.count - 2)
            var result = "\(senderEmail) \u{2192} \(displayParts.joined(separator: ", "))"
            if remaining > 0 { result += ", +\(remaining)" }
            self.cachedRecipientsLine = result
        }

        self.cachedFormattedDate = message.date?.formattedRelative
        self.cachedHasRemoteImages = cachedFullHTML.range(of: #"<img[^>]+src\s*=\s*["']https?://"#, options: .regularExpression) != nil

        let attNames = attachmentPairs.prefix(2).map { pair in
            let name = pair.0.name
            return name.count > 20 ? String(name.prefix(17)) + "..." : name
        }
        let attRemaining = attachmentPairs.count - attNames.count
        self.cachedCollapsedAttachmentSummary = attRemaining > 0
            ? attNames.joined(separator: ", ") + ", and \(attRemaining) more"
            : attNames.joined(separator: ", ")
    }

    // MARK: - Snippet text

    private var snippetText: String {
        if let snippet = message.snippet, !snippet.isEmpty { return snippet }
        if let plain = message.plainBody { return String(plain.prefix(100)) }
        return ""
    }

    // MARK: - Rendered HTML

    private var renderedHTML: String {
        if showQuoted || cachedHTMLParts.quoted == nil {
            return cachedFullHTML
        }
        return cachedHTMLParts.original
    }

    /// True when the email body contains at least one remote image reference (http/https src).
    private var hasRemoteImages: Bool { cachedHasRemoteImages }

    // MARK: - Collapsed Attachment Summary

    private var collapsedAttachmentSummary: String { cachedCollapsedAttachmentSummary }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }
                .onHover { isHovering = $0 }

            if !isExpanded && !attachmentPairs.isEmpty {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "paperclip")
                        .font(Typography.captionSmallRegular)
                    Text(collapsedAttachmentSummary)
                        .font(Typography.captionSmallRegular)
                        .lineLimit(1)
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.sm)
            }

            if isExpanded {
                expandedContent
                    .clipped()
                    .transition(.opacity.animation(reduceMotion ? nil : VikAnimation.springSnappy.delay(0.05)))
            }

            if !isLast {
                Divider()
                    .background(Color(.separatorColor))
            }
        }
        .glassEffect(
            isExpanded || isHovering ? .regular.interactive() : .identity,
            in: .rect(cornerRadius: CornerRadius.sm)
        )
        .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: isHovering)
        .overlay(alignment: .leading) {
            if isSentByMe {
                Rectangle()
                    .frame(width: 2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contextMenu {
            Button {
                onReply?(message)
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button {
                onReplyAll?(message)
            } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            Button {
                onForward?(message)
            } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }

            Divider()

            Button {
                onMarkUnread?(message)
            } label: {
                Label("Mark as Unread", systemImage: "envelope.badge")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.snippet ?? "", forType: .string)
            } label: {
                Label("Copy Message Text", systemImage: "doc.on.doc")
            }
        }
        .animation(reduceMotion ? nil : VikAnimation.springDefault, value: isExpanded)
        .onChange(of: message.id) { allowRemoteImages = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel({
            let senderName = isSentByMe ? "Me" : sender.name
            let dateText = cachedFormattedDate ?? ""
            let readState = message.isUnread ? "Unread" : "Read"
            if isExpanded {
                return "\(senderName), \(cachedRecipientsLine), \(dateText), \(readState)"
            } else {
                return "\(senderName), \(snippetText), \(dateText), \(readState)"
            }
        }())
        .accessibilityHint(isExpanded ? "Tap to collapse message" : "Tap to expand message")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: Spacing.sm) {
            ZStack {
                if message.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 6)

            HStack(spacing: 0) {
                AvatarView(
                    initials: sender.initials,
                    color: sender.avatarColor,
                    size: 24,
                    avatarURL: sender.avatarURL,
                    senderDomain: sender.domain
                )

                Text(isSentByMe ? "Me" : sender.name)
                    .font(message.isUnread ? Typography.calloutSemibold : Typography.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.leading, Spacing.sm)
            }
            .contactPopover(
                contact: sender,
                message: message,
                accountID: accountID,
                composeTo: { composeTo?($0) },
                searchSender: { searchSender?($0) }
            )

            VStack(alignment: .leading, spacing: isExpanded ? 2 : 0) {
                HStack {
                    if !isExpanded {
                        Text(snippetText)
                            .font(Typography.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }

                    Spacer(minLength: 4)

                    if !isExpanded && message.hasPartsWithFilenames {
                        Image(systemName: "paperclip")
                            .font(Typography.captionSmall)
                            .foregroundStyle(.tertiary)
                    }

                    if let formattedDate = cachedFormattedDate {
                        Text(formattedDate)
                            .font(Typography.captionRegular)
                            .foregroundStyle(.tertiary)
                    }
                }

                if isExpanded {
                    Text(cachedRecipientsLine)
                        .font(Typography.captionRegular)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .contactPopover(
                            contact: toContact,
                            message: message,
                            accountID: accountID,
                            composeTo: { composeTo?($0) },
                            searchSender: { searchSender?($0) }
                        )
                }
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .background(Color(.separatorColor).opacity(OpacityToken.divider))
                .padding(.horizontal, Spacing.xl)

            if hasRemoteImages && !allowRemoteImages && !alwaysLoadRemoteImages {
                HStack(spacing: Spacing.xsm) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(Typography.captionSmallRegular)
                        .foregroundStyle(.secondary)
                    Text("Remote images blocked")
                        .font(Typography.captionSmallRegular)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        allowRemoteImages = true
                    } label: {
                        Text("Load Images")
                            .font(Typography.captionSmallMedium)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Load remote images")
                    .help("Load blocked remote images")
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.xs)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }

            ZStack {
                if !isHTMLLoaded {
                    ContentShimmerView()
                        .padding(.horizontal, Spacing.xl)
                        .padding(.top, Spacing.sm)
                        .padding(.bottom, Spacing.md)
                        .transition(.opacity)
                }

                HTMLEmailView(
                    html: renderedHTML,
                    contentHeight: $contentHeight,
                    isContentLoaded: $isHTMLLoaded,
                    allowRemoteImages: allowRemoteImages || alwaysLoadRemoteImages,
                    onOpenLink: onOpenLink
                )
                .frame(height: contentHeight)
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.sm)
                .padding(.bottom, cachedHTMLParts.quoted != nil ? Spacing.xs : Spacing.md)
                .opacity(isHTMLLoaded ? 1 : 0)
            }
            .background(.quinary, in: RoundedRectangle(cornerRadius: CornerRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
            .padding(.horizontal, Spacing.md)
            .animation(reduceMotion ? nil : VikAnimation.contentSwitch, value: isHTMLLoaded)

            if cachedHTMLParts.quoted != nil {
                Button {
                    withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                        showQuoted.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showQuoted ? "chevron.up" : "chevron.down")
                            .font(Typography.captionSmallMedium)
                        Text(showQuoted ? "Hide quoted" : "Show quoted")
                            .font(Typography.captionSmallMedium)
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showQuoted ? "Hide quoted text" : "Show quoted text")
                .help(showQuoted ? "Hide quoted text" : "Show quoted text")
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            if !attachmentPairs.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.smd) {
                    HStack(spacing: Spacing.xsm) {
                        Image(systemName: "paperclip")
                            .font(Typography.subheadRegular)
                        Text("\(attachmentPairs.count) Attachment\(attachmentPairs.count > 1 ? "s" : "")")
                            .font(Typography.subhead)

                        Spacer()

                        if attachmentPairs.count > 1 {
                            Button {
                                onSaveAllAttachments?()
                            } label: {
                                Label("Save All", systemImage: "arrow.down.doc")
                                    .font(Typography.captionRegular)
                            }
                            .buttonStyle(.glass)
                            .opacity(isHovering ? 1 : 0)
                            .accessibilityHidden(!isHovering)
                            .animation(reduceMotion ? nil : VikAnimation.springSnappy, value: isHovering)
                        }
                    }
                    .foregroundStyle(.secondary)

                    if let progress = batchProgress {
                        HStack(spacing: Spacing.sm) {
                            ProgressView(
                                value: Double(progress.completed),
                                total: Double(progress.total)
                            )
                            .tint(.accentColor)

                            Text("Saving \(progress.completed) of \(progress.total)...")
                                .font(Typography.captionSmallRegular)
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .animation(reduceMotion ? nil : VikAnimation.springSnappy, value: progress)
                    }

                    GlassEffectContainer(spacing: Spacing.sm) {
                        HStack(spacing: Spacing.sm) {
                            ForEach(attachmentPairs, id: \.0.id) { (attachment, part) in
                                AttachmentChipView(
                                    attachment: attachment,
                                    isDownloading: downloadingAttachmentIDs.contains(attachment.gmailAttachmentId ?? ""),
                                    siblingCount: attachmentPairs.count,
                                    onPreview: part.map { p in { onPreviewAttachment?(attachment, p) } },
                                    onDownload: part.map { p in { onDownloadAttachment?(attachment, p) } },
                                    onOpen: part.map { p in { onOpenAttachment?(attachment, p) } },
                                    onSaveAll: { onSaveAllAttachments?() },
                                    onShare: part.map { p in { view in onShareAttachment?(attachment, p, view) } },
                                    onDragProvider: part.map { p in { onDragAttachment?(attachment, p) ?? NSItemProvider() } }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
                .accessibilityAction(named: "Save All Attachments") { onSaveAllAttachments?() }
            }
        }
    }
}

