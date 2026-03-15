import SwiftUI

struct EmailContextMenu: View {
    let email: Email
    let selectedFolder: Folder

    let onArchive: ((Email) -> Void)?
    let onDelete: ((Email) -> Void)?
    let onToggleStar: ((Email) -> Void)?
    let onMarkUnread: ((Email) -> Void)?
    let onMarkSpam: ((Email) -> Void)?
    let onUnsubscribe: ((Email) -> Void)?
    let onMoveToInbox: ((Email) -> Void)?
    let onDeletePermanently: ((Email) -> Void)?
    let onMarkNotSpam: ((Email) -> Void)?
    let onSnooze: ((Email, Date) -> Void)?
    let onCreateFilter: ((Email) -> Void)?
    var onReply: ((Email) -> Void)? = nil
    var onReplyAll: ((Email) -> Void)? = nil
    var onForward: ((Email) -> Void)? = nil

    var body: some View {
        Button { onReply?(email) } label: { Label("Reply",     systemImage: "arrowshape.turn.up.left") }
        Button { onReplyAll?(email) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
        Button { onForward?(email) } label: { Label("Forward",   systemImage: "arrowshape.turn.up.right") }

        Divider()

        if selectedFolder != .archive {
            Button { onArchive?(email) } label: { Label("Archive", systemImage: "archivebox") }
        }
        if selectedFolder != .trash {
            Button(role: .destructive) { onDelete?(email) } label: { Label("Move to Trash", systemImage: "trash") }
        }

        if selectedFolder == .archive || selectedFolder == .trash {
            Button { onMoveToInbox?(email) } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
        }

        if selectedFolder == .trash {
            Button(role: .destructive) { onDeletePermanently?(email) } label: { Label("Delete Permanently", systemImage: "trash.slash") }
        }

        if selectedFolder == .spam {
            Button { onMarkNotSpam?(email) } label: { Label("Not Spam", systemImage: "tray.and.arrow.down") }
        }

        if onSnooze != nil {
            Menu {
                ForEach(SnoozePreset.defaults()) { preset in
                    Button(preset.title) {
                        onSnooze?(email, preset.date)
                    }
                }
            } label: {
                Label("Snooze", systemImage: "clock")
            }
        }

        Divider()

        Button { onToggleStar?(email) } label: {
            Label(email.isStarred ? "Remove Star" : "Add Star",
                  systemImage: email.isStarred ? "star.slash" : "star")
        }
        Button { onMarkUnread?(email) } label: { Label("Mark as Unread", systemImage: "envelope.badge") }

        if email.isFromMailingList && email.unsubscribeURL != nil {
            Divider()
            Button(role: .destructive) { onUnsubscribe?(email) } label: {
                Label("Unsubscribe", systemImage: "xmark.circle")
            }
        }

        Divider()

        if let onCreateFilter {
            Button {
                onCreateFilter(email)
            } label: {
                Label("Create Filter...", systemImage: "line.3.horizontal.decrease.circle")
            }
        }

        if selectedFolder != .spam {
            Button(role: .destructive) { onMarkSpam?(email) } label: {
                Label("Report as Spam", systemImage: "exclamationmark.shield")
            }
        }
    }
}
