import SwiftUI

struct EmailToolbarItems: ToolbarContent {
    let selectedEmail: Email?
    let selectedFolder: Folder
    let isAnyPanelOpen: Bool
    @Binding var showSnoozePicker: Bool

    let onCompose: () -> Void
    let onReply: (Email) -> Void
    let onArchive: (Email) -> Void
    let onDelete: (Email) -> Void
    let onSnooze: (Email, Date) -> Void
    let onReplyAll: (Email) -> Void
    let onForward: (Email) -> Void
    let onToggleStar: (Email) -> Void
    let onMarkUnread: (Email) -> Void
    let onMoveToInbox: (Email) -> Void
    let onPrint: (Email) -> Void
    let onMarkNotSpam: (Email) -> Void
    let onMarkSpam: (Email) -> Void
    let onDeletePermanently: (Email) -> Void

    @State private var showDeletePermanentlyConfirmation = false
    @State private var showSpamConfirmation = false

    var body: some ToolbarContent {
        if !isAnyPanelOpen {
            ToolbarItem(placement: .primaryAction) {
                Button { onCompose() } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("Compose (\u{2318}N)")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            if let email = selectedEmail {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        onReply(email)
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.glass)
                    .help("Reply (\u{2318}R)")

                    if selectedFolder != .archive {
                        Button {
                            onArchive(email)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .buttonStyle(.glass)
                        .help("Archive (\u{2318}E)")
                    }

                    if selectedFolder != .trash {
                        Button {
                            onDelete(email)
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                        .buttonStyle(.glass)
                        .help("Move to Trash (\u{2318}\u{232B})")
                    }

                    Button {
                        showSnoozePicker = true
                    } label: {
                        Label("Snooze", systemImage: "clock")
                    }
                    .buttonStyle(.glass)
                    .help("Snooze")
                    .popover(isPresented: $showSnoozePicker) {
                        SnoozePickerView { date in
                            showSnoozePicker = false
                            onSnooze(email, date)
                        }
                    }
                }
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            if let email = selectedEmail {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button {
                            onReplyAll(email)
                        } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }

                        Button {
                            onForward(email)
                        } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }

                        Divider()

                        Button {
                            onToggleStar(email)
                        } label: {
                            Label(email.isStarred ? "Remove Star" : "Add Star", systemImage: email.isStarred ? "star.slash" : "star")
                        }

                        Button {
                            onMarkUnread(email)
                        } label: { Label("Mark as Unread", systemImage: "envelope.badge") }

                        if selectedFolder == .archive || selectedFolder == .trash {
                            Button {
                                onMoveToInbox(email)
                            } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
                        }

                        Divider()

                        Button {
                            onPrint(email)
                        } label: {
                            Label("Print", systemImage: "printer")
                        }
                        .disabled(email.gmailMessageID == nil)

                        Divider()

                        if selectedFolder == .spam {
                            Button {
                                onMarkNotSpam(email)
                            } label: { Label("Not Spam", systemImage: "tray.and.arrow.down") }
                        } else {
                            Button(role: .destructive) {
                                showSpamConfirmation = true
                            } label: { Label("Report as Spam", systemImage: "exclamationmark.shield") }
                        }

                        if selectedFolder == .trash {
                            Button(role: .destructive) {
                                showDeletePermanentlyConfirmation = true
                            } label: { Label("Delete Permanently", systemImage: "trash.slash") }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .help("More actions")
                    .confirmationDialog("Permanently delete this email? This cannot be undone.", isPresented: $showDeletePermanentlyConfirmation, titleVisibility: .visible) {
                        Button("Delete Permanently", role: .destructive) {
                            onDeletePermanently(email)
                        }
                    }
                    .confirmationDialog("Report this email as spam?", isPresented: $showSpamConfirmation, titleVisibility: .visible) {
                        Button("Report as Spam", role: .destructive) {
                            onMarkSpam(email)
                        }
                    }
                }
            }
        }
    }
}
