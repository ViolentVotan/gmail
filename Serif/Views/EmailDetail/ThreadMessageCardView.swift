import SwiftUI

struct ThreadMessageCardView: View {
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

    @State private var showQuoted = false
    @State private var contentHeight: CGFloat = 60
    @State private var showSenderInfo = false
    @State private var isHovering = false

    private let sender: Contact
    private let isSentByMe: Bool
    private let cachedFullHTML: String
    private let cachedHTMLParts: (original: String, quoted: String?)

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
        onDownloadAttachment: ((Attachment, GmailMessagePart) -> Void)? = nil
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

        let parsedSender = GmailDataTransformer.parseContact(message.from)
        self.sender = parsedSender
        self.isSentByMe = !fromAddress.isEmpty && parsedSender.email.lowercased() == fromAddress.lowercased()

        let html = GmailThreadMessageView.computeFullHTML(message: message, resolvedHTML: resolvedHTML)
        self.cachedFullHTML = html
        self.cachedHTMLParts = GmailThreadMessageView.stripQuotedHTML(html)
    }

    // MARK: - Snippet text

    private var snippetText: String {
        if let snippet = message.snippet, !snippet.isEmpty { return snippet }
        if let plain = message.plainBody { return String(plain.prefix(100)) }
        return ""
    }

    // MARK: - Recipients line

    private var recipientsLine: String {
        let parts = message.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return sender.email }
        let displayParts = parts.prefix(2).map { part -> String in
            // Extract email from "Name <email>" format for comparison
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
        var result = "\(sender.email) \u{2192} \(displayParts.joined(separator: ", "))"
        if remaining > 0 { result += ", +\(remaining)" }
        return result
    }

    // MARK: - Rendered HTML

    private var renderedHTML: String {
        if showQuoted || cachedHTMLParts.quoted == nil {
            return cachedFullHTML
        }
        return cachedHTMLParts.original
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }
                .onHover { isHovering = $0 }

            if isExpanded {
                expandedContent
                    .clipped()
                    .transition(.opacity.animation(.easeIn(duration: 0.15)))
            }

            if !isLast {
                Divider()
                    .background(Color(.separatorColor))
            }
        }
        .background(isHovering && !isExpanded ? Color(.quaternaryLabelColor) : Color.clear)
        .overlay(alignment: .leading) {
            if isSentByMe {
                Rectangle()
                    .frame(width: 2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .animation(SerifAnimation.springSnappy, value: isExpanded)
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: 8) {
            ZStack {
                if message.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 6)

            AvatarView(
                initials: sender.initials,
                color: sender.avatarColor,
                size: 24,
                avatarURL: sender.avatarURL,
                senderDomain: sender.domain
            )

            VStack(alignment: .leading, spacing: isExpanded ? 2 : 0) {
                HStack {
                    Text(isSentByMe ? "Me" : sender.name)
                        .font(message.isUnread ? Typography.calloutSemibold : Typography.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

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

                    if let date = message.date {
                        Text(date.formattedRelative)
                            .font(Typography.captionRegular)
                            .foregroundStyle(.tertiary)
                    }
                }

                if isExpanded {
                    Text(recipientsLine)
                        .font(Typography.captionRegular)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .onTapGesture { showSenderInfo.toggle() }
                        .pointerStyle(.link)
                        .popover(isPresented: $showSenderInfo, arrowEdge: .bottom) {
                            SenderInfoPopover(message: message)
                        }
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
                .background(Color(.separatorColor).opacity(0.5))
                .padding(.horizontal, Spacing.xl)

            HTMLEmailView(html: renderedHTML, contentHeight: $contentHeight, onOpenLink: onOpenLink)
                .frame(height: contentHeight)
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.sm)
                .padding(.bottom, cachedHTMLParts.quoted != nil ? Spacing.xs : Spacing.md)

            if cachedHTMLParts.quoted != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            if !attachmentPairs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(Typography.subheadRegular)
                        Text("\(attachmentPairs.count) Attachment\(attachmentPairs.count > 1 ? "s" : "")")
                            .font(Typography.subhead)
                    }
                    .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach(attachmentPairs, id: \.0.id) { (attachment, part) in
                            AttachmentChipView(
                                attachment: attachment,
                                onPreview: part.map { p in { onPreviewAttachment?(attachment, p) } },
                                onDownload: part.map { p in { onDownloadAttachment?(attachment, p) } }
                            )
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }
        }
    }
}
