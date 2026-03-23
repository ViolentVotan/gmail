import SwiftUI

struct EmailToolbarItems: ToolbarContent {
    let coordinator: AppCoordinator
    @Binding var showSnoozePicker: Bool
    @State private var showDeletePermanentlyConfirmation = false
    @State private var showSpamConfirmation = false

    var body: some ToolbarContent {
        if !coordinator.panelCoordinator.isAnyOpen {
            ToolbarItem(placement: .primaryAction) {
                Button { coordinator.composeNewEmail() } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Compose (\u{2318}N)")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            if let email = coordinator.selection.selectedEmail {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        coordinator.startCompose(mode: EmailDetailViewModel.replyMode(for: email))
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.glass)
                    .help("Reply")

                    if coordinator.navigation.selectedFolder != .archive {
                        Button {
                            Task { await coordinator.actionCoordinator.archiveEmail(email, selectNext: { coordinator.selection.selectNext($0) }) }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .buttonStyle(.glass)
                        .help("Archive (\u{2318}E)")
                    }

                    if coordinator.navigation.selectedFolder != .trash {
                        Button {
                            Task { await coordinator.actionCoordinator.deleteEmail(email, selectNext: { coordinator.selection.selectNext($0) }) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.glass)
                        .help("Delete (\u{2318}\u{232B})")
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
                            Task { await coordinator.actionCoordinator.snoozeEmail(email, until: date, selectNext: { coordinator.selection.selectNext($0) }) }
                        }
                    }
                }
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            if let email = coordinator.selection.selectedEmail {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button {
                            coordinator.startCompose(mode: EmailDetailViewModel.replyAllMode(for: email))
                        } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }

                        Button {
                            coordinator.startCompose(mode: EmailDetailViewModel.forwardMode(for: email))
                        } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }

                        Divider()

                        Button {
                            Task { await coordinator.actionCoordinator.toggleStarEmail(email) }
                        } label: {
                            Label(email.isStarred ? "Remove from Favorites" : "Add to Favorites", systemImage: email.isStarred ? "star.slash" : "star")
                        }

                        Button {
                            Task { await coordinator.actionCoordinator.markUnreadEmail(email) }
                        } label: { Label("Mark as Unread", systemImage: "envelope.badge") }

                        if coordinator.navigation.selectedFolder == .archive || coordinator.navigation.selectedFolder == .trash {
                            Button {
                                Task { await coordinator.actionCoordinator.moveToInboxEmail(email, selectedFolder: coordinator.navigation.selectedFolder, selectNext: { coordinator.selection.selectNext($0) }) }
                            } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
                        }

                        Divider()

                        Button {
                            Task { await coordinator.actionCoordinator.printEmail(email) }
                        } label: {
                            Label("Print", systemImage: "printer")
                        }
                        .disabled(email.gmailMessageID == nil)

                        Divider()

                        if coordinator.navigation.selectedFolder == .spam {
                            Button {
                                Task { await coordinator.actionCoordinator.markNotSpamEmail(email, selectNext: { coordinator.selection.selectNext($0) }) }
                            } label: { Label("Not Spam", systemImage: "tray.and.arrow.down") }
                        } else {
                            Button(role: .destructive) {
                                showSpamConfirmation = true
                            } label: { Label("Report as Spam", systemImage: "exclamationmark.shield") }
                        }

                        if coordinator.navigation.selectedFolder == .trash {
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
                            Task { await coordinator.actionCoordinator.deletePermanentlyEmail(email, selectNext: { coordinator.selection.selectNext($0) }) }
                        }
                    }
                    .confirmationDialog("Report this email as spam?", isPresented: $showSpamConfirmation, titleVisibility: .visible) {
                        Button("Report as Spam", role: .destructive) {
                            Task { await coordinator.actionCoordinator.markSpamEmail(email, selectNext: { coordinator.selection.selectNext($0) }) }
                        }
                    }
                }
            }
        }
    }
}
