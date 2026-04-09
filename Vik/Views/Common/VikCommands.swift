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

struct VikCommands: Commands {
    @FocusedValue(\.appCoordinator) private var coordinator
    @FocusedValue(\.commandPalette) private var commandPalette

    private var selectedEmail: Email? { coordinator?.selection.selectedEmail }
    private var hasSelection: Bool { selectedEmail != nil }
    private var isInbox: Bool { coordinator?.navigation.selectedFolder == .inbox }

    private var isStarred: Bool { selectedEmail?.isStarred ?? false }
    private var isRead: Bool { selectedEmail?.isRead ?? true }

    var body: some Commands {
        messageMenu
        mailboxMenu
        viewMenu
        helpMenu
    }

    // MARK: - Message

    private var messageMenu: some Commands {
        CommandMenu("Message") {
            Button {
                guard let coordinator, let email = selectedEmail else { return }
                Task { await coordinator.actionCoordinator.archiveEmail(email, selectNext: { coordinator.selection.selectNext($0) }) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!hasSelection)

            Button {
                guard let coordinator, let email = selectedEmail else { return }
                Task { await coordinator.actionCoordinator.deleteEmail(email, selectNext: { coordinator.selection.selectNext($0) }) }
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!hasSelection)

            Button {
                guard let coordinator, let email = selectedEmail else { return }
                Task { await coordinator.actionCoordinator.moveToInboxEmail(email, selectedFolder: coordinator.navigation.selectedFolder, selectNext: { coordinator.selection.selectNext($0) }) }
            } label: {
                Label("Move to Inbox", systemImage: "tray.and.arrow.down")
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(!hasSelection || coordinator?.navigation.selectedFolder == .inbox)

            Divider()

            Button {
                guard let coordinator, let email = selectedEmail else { return }
                coordinator.startCompose(mode: EmailDetailViewModel.replyMode(for: email))
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!hasSelection)

            Button {
                guard let coordinator, let email = selectedEmail else { return }
                coordinator.startCompose(mode: EmailDetailViewModel.replyAllMode(for: email))
            } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!hasSelection)

            Button {
                guard let coordinator, let email = selectedEmail else { return }
                coordinator.startCompose(mode: EmailDetailViewModel.forwardMode(for: email))
            } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!hasSelection)

            Divider()

            Button {
                guard let coordinator, let email = selectedEmail else { return }
                Task { await coordinator.actionCoordinator.toggleStarEmail(email) }
            } label: {
                Label(isStarred ? "Remove Star" : "Add Star", systemImage: isStarred ? "star.slash" : "star")
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!hasSelection)

            Button {
                guard let coordinator, let email = selectedEmail else { return }
                if isRead {
                    Task { await coordinator.actionCoordinator.markUnreadEmail(email) }
                } else {
                    Task { await coordinator.actionCoordinator.markReadEmail(email) }
                }
            } label: {
                Label(isRead ? "Mark as Unread" : "Mark as Read", systemImage: isRead ? "envelope.badge" : "envelope.open")
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!hasSelection)
        }
    }

    // MARK: - Mailbox

    private var isCalendarMode: Bool { coordinator?.calendar.viewMode == .calendar }

    private var mailboxMenu: some Commands {
        CommandMenu("Mailbox") {
            Button {
                if isCalendarMode {
                    coordinator?.calendar.calendarNewEventTrigger = true
                } else {
                    coordinator?.composeNewEmail()
                }
            } label: {
                Label(isCalendarMode ? "New Event" : "Compose New Message",
                      systemImage: isCalendarMode ? "calendar.badge.plus" : "square.and.pencil")
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
            .keyboardShortcut("r", modifiers: [.command, .option])

            Button {
                coordinator?.navigation.searchFocusTrigger = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }


    // MARK: - View

    private var viewMenu: some Commands {
        CommandMenu("View") {
            Button {
                coordinator?.switchToMail()
            } label: {
                Label("Mail", systemImage: "envelope")
            }
            .keyboardShortcut("1", modifiers: .command)

            Button {
                coordinator?.switchToCalendar()
            } label: {
                Label("Calendar", systemImage: "calendar")
            }
            .keyboardShortcut("2", modifiers: .command)

            Divider()

            Button {
                coordinator?.calendar.calendarViewModel?.goToToday()
            } label: {
                Label("Go to Today", systemImage: "calendar.circle")
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(!isCalendarMode)
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
