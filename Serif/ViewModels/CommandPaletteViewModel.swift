import SwiftUI

@Observable
@MainActor
final class CommandPaletteViewModel {
    var query = ""
    var isVisible = false
    var selectedIndex = 0

    private var allCommands: [Command] = []

    var filteredCommands: [Command] {
        let matched = query.isEmpty ? allCommands : allCommands.filter { $0.matches(query) }
        return Array(matched.prefix(10))
    }

    func toggle() {
        isVisible.toggle()
        if isVisible {
            query = ""
            selectedIndex = 0
        }
    }

    func dismiss() {
        isVisible = false
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
        allCommands = [
            Command(id: "action.compose", title: "Compose New Email", icon: "square.and.pencil") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.composeNewEmail()
            },
            Command(id: "action.refresh", title: "Refresh", icon: "arrow.clockwise") { [weak coordinator] in
                guard let coordinator else { return }
                Task { await coordinator.loadCurrentFolder() }
            },
            Command(id: "folder.inbox", title: "Go to Inbox", icon: "tray") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.selectedFolder = .inbox
            },
            Command(id: "folder.sent", title: "Go to Sent", icon: "paperplane") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.selectedFolder = .sent
            },
            Command(id: "folder.drafts", title: "Go to Drafts", icon: "doc") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.selectedFolder = .drafts
            },
            Command(id: "folder.archive", title: "Go to Archive", icon: "archivebox") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.selectedFolder = .archive
            },
            Command(id: "folder.trash", title: "Go to Trash", icon: "trash") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.selectedFolder = .trash
            },
            Command(id: "folder.starred", title: "Go to Starred", icon: "star") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.selectedFolder = .starred
            },
            Command(id: "folder.snoozed", title: "Go to Snoozed", icon: "clock.fill") { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.selectedFolder = .snoozed
            },
            Command(id: "settings.open", title: "Open Settings", icon: "gear") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
        ]
    }

}
