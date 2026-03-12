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

    var body: some View {
        Button { } label: { Label("Reply",     systemImage: "arrowshape.turn.up.left") }
        Button { } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
        Button { } label: { Label("Forward",   systemImage: "arrowshape.turn.up.right") }

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
                ForEach(["Later Today", "Tomorrow Morning", "Next Week"], id: \.self) { label in
                    Button(label) {
                        let date: Date = {
                            let cal = Calendar.current
                            switch label {
                            case "Later Today": return cal.date(byAdding: .hour, value: 3, to: Date()) ?? Date()
                            case "Tomorrow Morning":
                                let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                                return cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
                            default:
                                let weekday = cal.component(.weekday, from: Date())
                                let daysUntilMonday = (9 - weekday) % 7
                                let monday = cal.date(byAdding: .day, value: daysUntilMonday == 0 ? 7 : daysUntilMonday, to: Date()) ?? Date()
                                return cal.date(bySettingHour: 8, minute: 0, second: 0, of: monday) ?? monday
                            }
                        }()
                        onSnooze?(email, date)
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

        if selectedFolder != .spam {
            Button(role: .destructive) { onMarkSpam?(email) } label: {
                Label("Report as Spam", systemImage: "exclamationmark.shield")
            }
        }
    }
}
