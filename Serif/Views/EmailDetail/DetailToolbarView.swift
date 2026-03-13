import SwiftUI

struct DetailToolbarView: View {
    let email: Email
    let detailVM: EmailDetailViewModel
    let isMailingList: Bool
    let resolvedUnsubscribeURL: URL?
    let oneClick: Bool
    let alreadyUnsubscribed: Bool
    var onArchive: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSnooze: ((Date) -> Void)?
    var onMoveToInbox: (() -> Void)?
    var onDeletePermanently: (() -> Void)?
    var onMarkNotSpam: (() -> Void)?
    var onToggleStar: ((Bool) -> Void)?
    var onMarkUnread: (() -> Void)?
    var onReply: ((ComposeMode) -> Void)?
    var onReplyAll: ((ComposeMode) -> Void)?
    var onForward: ((ComposeMode) -> Void)?
    var onShowOriginal: ((EmailDetailViewModel) -> Void)?
    var onDownloadMessage: ((EmailDetailViewModel) -> Void)?
    var onUnsubscribe: ((URL, Bool, String?) async -> Bool)?
    var onPrint: ((GmailMessage, Email) -> Void)?
    let replyMode: () -> ComposeMode
    let replyAllMode: () -> ComposeMode
    let forwardMode: () -> ComposeMode

    @State private var isUnsubscribing = false
    @State private var showSnoozePicker = false
    @Binding var didUnsubscribe: Bool
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 30

    var body: some View {
        HStack(spacing: Spacing.md) {
            Spacer()

            // Unsubscribe button — only shown for mailing lists
            if isMailingList, let url = resolvedUnsubscribeURL {
                if alreadyUnsubscribed {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(Typography.captionSmall)
                        Text("Unsubscribed")
                            .font(Typography.subhead)
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary)
                    .clipShape(.rect(cornerRadius: CornerRadius.sm))
                } else {
                    Button {
                        isUnsubscribing = true
                        Task {
                            let msgID = email.gmailMessageID
                            let success = await onUnsubscribe?(url, oneClick, msgID) ?? false
                            isUnsubscribing = false
                            if success { didUnsubscribe = true }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isUnsubscribing {
                                ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                            }
                            Text("Unsubscribe")
                                .font(Typography.subhead)
                        }
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.1))
                        .clipShape(.rect(cornerRadius: CornerRadius.sm))
                    }
                    .buttonStyle(.plain)
                    .disabled(isUnsubscribing)
                    .help(oneClick ? "One-click unsubscribe" : "Open unsubscribe page")
                }

            }

            if let onArchive {
                toolbarButton(icon: "archivebox", label: "Archive") { onArchive() }
            }
            if let onDelete {
                toolbarButton(icon: "trash", label: "Delete") { onDelete() }
            }
            if let onMoveToInbox {
                toolbarButton(icon: "tray.and.arrow.down", label: "Move to Inbox") { onMoveToInbox() }
            }
            if let onSnooze {
                Button {
                    showSnoozePicker = true
                } label: {
                    Image(systemName: "clock")
                        .font(.body)
                        .frame(width: buttonSize, height: buttonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.glass)
                .help("Snooze")
                .popover(isPresented: $showSnoozePicker) {
                    SnoozePickerView { date in
                        showSnoozePicker = false
                        onSnooze(date)
                    }
                }
            }

            Menu {
                Section {
                    Button { onReply?(replyMode()) }    label: { Label("Reply",     systemImage: "arrowshape.turn.up.left") }
                    Button { onReplyAll?(replyAllMode()) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                    Button { onForward?(forwardMode()) }  label: { Label("Forward",   systemImage: "arrowshape.turn.up.right") }
                }
                Divider()
                Section {
                    Button { onMarkUnread?() } label: { Label("Mark as Unread",     systemImage: "envelope.badge") }
                    Button {
                        let starred = detailVM.latestMessage?.isStarred ?? email.isStarred
                        detailVM.toggleStar()
                        onToggleStar?(starred)
                    } label: {
                        let starred = detailVM.latestMessage?.isStarred ?? email.isStarred
                        Label(starred ? "Remove from Favorites" : "Add to Favorites", systemImage: starred ? "star.slash" : "star")
                    }
                }
                Divider()
                Section {
                    Button {
                        if let msg = detailVM.latestMessage {
                            onPrint?(msg, email)
                        }
                    } label: { Label("Print", systemImage: "printer") }
                    Button { onDownloadMessage?(detailVM) } label: { Label("Download Message", systemImage: "arrow.down.circle") }
                    Button { onShowOriginal?(detailVM) } label: { Label("Show Original",    systemImage: "doc.text") }
                }
                Divider()
                Section {
                    // TODO: Implement mute thread and block sender features
                    // Button { } label: { Label("Mute Thread", systemImage: "bell.slash") }
                    // Button { } label: { Label("Block Sender", systemImage: "hand.raised") }
                    if let onMarkNotSpam {
                        Button { onMarkNotSpam() } label: { Label("Not Spam", systemImage: "tray.and.arrow.down") }
                    } else {
                        Button(role: .destructive) { onDelete?() } label: { Label("Report as Spam", systemImage: "exclamationmark.shield") }
                    }
                    if let onDeletePermanently {
                        Button(role: .destructive) { onDeletePermanently() } label: { Label("Delete Permanently", systemImage: "trash.slash") }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .help("More")
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
        .glassEffect(.regular, in: .capsule)
        .elevation(.navigation)
    }

    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .help(label)
    }
}
