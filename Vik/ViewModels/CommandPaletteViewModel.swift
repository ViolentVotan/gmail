import SwiftUI

@Observable
@MainActor
final class CommandPaletteViewModel {
    var query: String = "" {
        didSet { updateFilteredCommands() }
    }
    var isVisible = false
    var selectedIndex = 0

    private var allCommands: [Command] = []
    private(set) var filteredCommands: [Command] = []

    /// Cached coordinator reference for building dynamic commands.
    private weak var coordinator: AppCoordinator?

    private func updateFilteredCommands() {
        var matched = query.isEmpty ? allCommands : allCommands.filter { $0.matches(query) }

        // Dynamic "Create event: <input>" entry when nothing matches.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, matched.isEmpty || !matched.contains(where: { $0.id.hasPrefix("calendar.") }) {
            let text = trimmed
            let dynamic = Command(
                id: "calendar.quickadd.dynamic",
                title: "Create event: \"\(text)\"",
                subtitle: "Quick-add via Google Calendar",
                icon: "calendar.badge.plus"
            ) { [weak self] in
                guard let coordinator = self?.coordinator else { return }
                guard let calendarVM = coordinator.calendar.calendarViewModel else {
                    coordinator.switchToCalendar()
                    return
                }
                Task {
                    do {
                        try await calendarVM.quickAddEvent(
                            text: text,
                            calendarId: "primary",
                            accountID: coordinator.navigation.accountID
                        )
                        ToastManager.shared.show(message: "Event created")
                    } catch {
                        ToastManager.shared.show(message: "Could not create event", type: .error)
                    }
                }
            }
            matched = Array((matched + [dynamic]).prefix(10))
        } else {
            matched = Array(matched.prefix(10))
        }

        filteredCommands = matched
        selectedIndex = 0
    }

    func toggle() {
        withAnimation(VikAnimation.springDefault) {
            isVisible.toggle()
        }
        if isVisible {
            query = ""
            selectedIndex = 0
        }
    }

    func dismiss() {
        withAnimation(VikAnimation.springDefault) {
            isVisible = false
        }
        query = ""
    }

    func executeSelected() {
        guard selectedIndex < filteredCommands.count else { return }
        let command = filteredCommands[selectedIndex]
        command.action()
        dismiss()
    }

    func moveUp() {
        guard selectedIndex > 0 else { return }
        selectedIndex -= 1
    }

    func moveDown() {
        guard selectedIndex < filteredCommands.count - 1 else { return }
        selectedIndex += 1
    }

    func buildCommands(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        allCommands = [
            // MARK: Email actions
            Command(id: "action.compose", title: "Compose New Email", icon: "square.and.pencil") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.composeNewEmail()
            },
            Command(id: "action.refresh", title: "Refresh", icon: "arrow.clockwise") { [weak coordinator] in
                guard let coordinator else { return }
                Task { await coordinator.loadCurrentFolder() }
            },

            // MARK: Folders
            Command(id: "folder.inbox", title: "Go to Inbox", icon: "tray") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.navigation.selectedFolder = .inbox
            },
            Command(id: "folder.sent", title: "Go to Sent", icon: "paperplane") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.navigation.selectedFolder = .sent
            },
            Command(id: "folder.drafts", title: "Go to Drafts", icon: "doc") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.navigation.selectedFolder = .drafts
            },
            Command(id: "folder.archive", title: "Go to Archive", icon: "archivebox") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.navigation.selectedFolder = .archive
            },
            Command(id: "folder.trash", title: "Go to Trash", icon: "trash") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.navigation.selectedFolder = .trash
            },
            Command(id: "folder.starred", title: "Go to Starred", icon: "star") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.navigation.selectedFolder = .starred
            },
            Command(id: "folder.snoozed", title: "Go to Snoozed", icon: "clock.fill") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.navigation.selectedFolder = .snoozed
            },

            // MARK: Calendar — mode & navigation
            Command(id: "calendar.show", title: "Show Calendar", icon: "calendar") { [weak coordinator] in
                coordinator?.switchToCalendar()
            },
            Command(id: "calendar.create", title: "Create Event", icon: "calendar.badge.plus") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.switchToCalendar()
                // calendarViewModel receives a new-event signal via selectedDate reset to now.
                coordinator.calendar.calendarViewModel?.selectedDate = .now
                coordinator.calendar.calendarViewModel?.selectedEvent = nil
                ToastManager.shared.show(message: "Use the + button to create an event")
            },
            Command(id: "calendar.today", title: "Go to Today", icon: "calendar.day.timeline.left") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.switchToCalendar()
                coordinator.calendar.calendarViewModel?.goToToday()
            },
            Command(id: "calendar.next_week", title: "Next Week", icon: "chevron.right") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.switchToCalendar()
                coordinator.calendar.calendarViewModel?.navigateForward()
            },
            Command(id: "calendar.prev_week", title: "Previous Week", icon: "chevron.left") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.switchToCalendar()
                coordinator.calendar.calendarViewModel?.navigateBackward()
            },

            // MARK: Calendar — smart queries
            Command(
                id: "calendar.next_meeting",
                title: "What's my next meeting?",
                icon: "clock.arrow.circlepath"
            ) { [weak coordinator] in
                guard let coordinator, let db = coordinator.sync.mailDatabase else { return }
                let accountID = coordinator.navigation.accountID
                Task {
                    let event = await CalendarIntegrationService.shared.nextMeetingWith(
                        email: accountID,
                        accountID: accountID,
                        db: db
                    )
                    if let event {
                        let time = event.startTime.formattedTime
                        ToastManager.shared.show(message: "\(event.summary) at \(time)")
                        coordinator.navigateToEvent(event)
                    } else {
                        // Fall back to showing today in calendar
                        coordinator.switchToCalendar()
                        coordinator.calendar.calendarViewModel?.goToToday()
                        ToastManager.shared.show(message: "No upcoming meetings found")
                    }
                }
            },

            // MARK: Settings
            Command(id: "settings.open", title: "Open Settings", icon: "gear") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
        ]
        updateFilteredCommands()
    }

}
