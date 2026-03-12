import SwiftUI

// MARK: - Commands

struct AppCoordinatorFocusedKey: FocusedValueKey {
    typealias Value = AppCoordinator
}

extension FocusedValues {
    var appCoordinator: AppCoordinator? {
        get { self[AppCoordinatorFocusedKey.self] }
        set { self[AppCoordinatorFocusedKey.self] = newValue }
    }
}

struct CommandPaletteFocusedKey: FocusedValueKey {
    typealias Value = CommandPaletteViewModel
}

extension FocusedValues {
    var commandPalette: CommandPaletteViewModel? {
        get { self[CommandPaletteFocusedKey.self] }
        set { self[CommandPaletteFocusedKey.self] = newValue }
    }
}

struct SerifCommands: Commands {
    @FocusedValue(\.appCoordinator) private var coordinator
    @FocusedValue(\.commandPalette) private var commandPalette

    private var selectedEmail: Email? { coordinator?.selectedEmail }
    private var hasSelection: Bool { selectedEmail != nil }
    private var isInbox: Bool { coordinator?.selectedFolder == .inbox }

    /// Read live state from the mailbox viewmodel (source of truth) rather than
    /// the selectedEmail snapshot which may be stale.
    private var liveMessage: GmailMessage? {
        guard let msgID = selectedEmail?.gmailMessageID else { return nil }
        return coordinator?.mailboxViewModel.messages.first { $0.id == msgID }
    }
    private var isStarred: Bool { liveMessage?.isStarred ?? selectedEmail?.isStarred ?? false }
    private var isRead: Bool { !(liveMessage?.isUnread ?? !(selectedEmail?.isRead ?? true)) }

    var body: some Commands {
        messageMenu
        mailboxMenu
        helpMenu
    }

    // MARK: - Message

    private var messageMenu: some Commands {
        CommandMenu("Message") {
            Button {
                guard let coordinator, let email = selectedEmail else { return }
                coordinator.actionCoordinator.archiveEmail(email, selectNext: { coordinator.selectNext($0) })
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!hasSelection)

            Button {
                guard let coordinator, let email = selectedEmail else { return }
                coordinator.actionCoordinator.deleteEmail(email, selectNext: { coordinator.selectNext($0) })
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!hasSelection)

            Button {
                guard let coordinator, let email = selectedEmail else { return }
                coordinator.actionCoordinator.moveToInboxEmail(email, selectedFolder: coordinator.selectedFolder, selectNext: { coordinator.selectNext($0) })
            } label: {
                Label("Move to Inbox", systemImage: "tray.and.arrow.down")
            }
            .disabled(!hasSelection || coordinator?.selectedFolder == .inbox)

            Divider()

            Button {
                guard let coordinator, let msgID = selectedEmail?.gmailMessageID else { return }
                Task { await coordinator.mailboxViewModel.toggleStar(msgID, isStarred: isStarred) }
            } label: {
                Label(isStarred ? "Remove Star" : "Add Star", systemImage: isStarred ? "star.slash" : "star")
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!hasSelection)

            Button {
                guard let coordinator, let email = selectedEmail, let msgID = email.gmailMessageID else { return }
                if isRead {
                    coordinator.actionCoordinator.markUnreadEmail(email)
                } else if let message = coordinator.mailboxViewModel.messages.first(where: { $0.id == msgID }) {
                    Task { await coordinator.mailboxViewModel.markAsRead(message) }
                }
            } label: {
                Label(isRead ? "Mark as Unread" : "Mark as Read", systemImage: isRead ? "envelope.badge" : "envelope.open")
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!hasSelection)
        }
    }

    // MARK: - Mailbox

    private var mailboxMenu: some Commands {
        CommandMenu("Mailbox") {
            Button {
                coordinator?.composeNewEmail()
            } label: {
                Label("Compose New Message", systemImage: "square.and.pencil")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button {
                commandPalette?.toggle()
            } label: {
                Label("Command Palette", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button {
                guard let coordinator else { return }
                Task { await coordinator.loadCurrentFolder() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button {
                coordinator?.searchFocusTrigger = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }


    // MARK: - Help

    private var helpMenu: some Commands {
        CommandGroup(replacing: .help) {
            Button {
                coordinator?.panelCoordinator.showHelp = true
            } label: {
                Label("Keyboard Shortcuts", systemImage: "keyboard")
            }
        }
    }
}
