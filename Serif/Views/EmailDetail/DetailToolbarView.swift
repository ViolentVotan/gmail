import SwiftUI

struct DetailToolbarView: View {
    let email: Email
    let detailVM: EmailDetailViewModel
    let isMailingList: Bool
    let resolvedUnsubscribeURL: URL?
    let oneClick: Bool
    let alreadyUnsubscribed: Bool
    let actions: EmailDetailActions
    let replyMode: () -> ComposeMode
    let replyAllMode: () -> ComposeMode
    let forwardMode: () -> ComposeMode

    @State private var isUnsubscribing = false
    @State private var showSnoozePicker = false
    @Binding var didUnsubscribe: Bool
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = ButtonSize.lg

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer {
                    toolbarContent
                }
            } else {
                toolbarContent
            }
        }
    }

    private var toolbarContent: some View {
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
                            let success = await actions.onUnsubscribe?(url, oneClick, msgID) ?? false
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

            if let onArchive = actions.onArchive {
                ToolbarIconButton(icon: "archivebox", label: "Archive", size: buttonSize, useGlass: true) { onArchive() }
            }
            if let onDelete = actions.onDelete {
                ToolbarIconButton(icon: "trash", label: "Delete", size: buttonSize, useGlass: true) { onDelete() }
            }
            if let onMoveToInbox = actions.onMoveToInbox {
                ToolbarIconButton(icon: "tray.and.arrow.down", label: "Move to Inbox", size: buttonSize, useGlass: true) { onMoveToInbox() }
            }
            if let onSnooze = actions.onSnooze {
                Button {
                    showSnoozePicker = true
                } label: {
                    Image(systemName: "clock")
                        .font(Typography.body)
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
                    Button { actions.onReply?(replyMode()) }    label: { Label("Reply",     systemImage: "arrowshape.turn.up.left") }
                    Button { actions.onReplyAll?(replyAllMode()) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                    Button { actions.onForward?(forwardMode()) }  label: { Label("Forward",   systemImage: "arrowshape.turn.up.right") }
                }
                Divider()
                Section {
                    Button { actions.onMarkUnread?() } label: { Label("Mark as Unread",     systemImage: "envelope.badge") }
                    Button {
                        let starred = detailVM.latestMessage?.isStarred ?? email.isStarred
                        detailVM.toggleStar()
                        actions.onToggleStar?(starred)
                    } label: {
                        let starred = detailVM.latestMessage?.isStarred ?? email.isStarred
                        Label(starred ? "Remove from Favorites" : "Add to Favorites", systemImage: starred ? "star.slash" : "star")
                    }
                }
                Divider()
                Section {
                    Button {
                        if let msg = detailVM.latestMessage {
                            actions.onPrint?(msg, email)
                        }
                    } label: { Label("Print", systemImage: "printer") }
                    Button { actions.onDownloadMessage?(detailVM) } label: { Label("Download Message", systemImage: "arrow.down.circle") }
                    Button { actions.onShowOriginal?(detailVM) } label: { Label("Show Original",    systemImage: "doc.text") }
                }
                Divider()
                Section {
                    // TODO: Implement mute thread and block sender features
                    // Button { } label: { Label("Mute Thread", systemImage: "bell.slash") }
                    // Button { } label: { Label("Block Sender", systemImage: "hand.raised") }
                    if let onMarkNotSpam = actions.onMarkNotSpam {
                        Button { onMarkNotSpam() } label: { Label("Not Spam", systemImage: "tray.and.arrow.down") }
                    } else {
                        Button(role: .destructive) { actions.onDelete?() } label: { Label("Report as Spam", systemImage: "exclamationmark.shield") }
                    }
                    if let onDeletePermanently = actions.onDeletePermanently {
                        Button(role: .destructive) { onDeletePermanently() } label: { Label("Delete Permanently", systemImage: "trash.slash") }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(Typography.body)
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

}
