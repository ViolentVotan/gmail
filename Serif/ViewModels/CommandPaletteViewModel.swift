import SwiftUI

@Observable
@MainActor
final class CommandPaletteViewModel {
    var query = ""
    var isVisible = false
    var selectedIndex = 0

    private var allCommands: [Command] = []
    private var recentCommandIDs: [String] = []

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
        trackRecent(command.id)
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
            Command(id: "action.compose", title: "Compose New Email", icon: "square.and.pencil", group: .actions) {
                coordinator.composeNewEmail()
            },
            Command(id: "action.refresh", title: "Refresh", icon: "arrow.clockwise", group: .actions) {
                Task { await coordinator.loadCurrentFolder() }
            },
            Command(id: "folder.inbox", title: "Go to Inbox", icon: "tray", group: .navigation) {
                coordinator.selectedFolder = .inbox
            },
            Command(id: "folder.sent", title: "Go to Sent", icon: "paperplane", group: .navigation) {
                coordinator.selectedFolder = .sent
            },
            Command(id: "folder.drafts", title: "Go to Drafts", icon: "doc", group: .navigation) {
                coordinator.selectedFolder = .drafts
            },
            Command(id: "folder.archive", title: "Go to Archive", icon: "archivebox", group: .navigation) {
                coordinator.selectedFolder = .archive
            },
            Command(id: "folder.trash", title: "Go to Trash", icon: "trash", group: .navigation) {
                coordinator.selectedFolder = .trash
            },
            Command(id: "folder.starred", title: "Go to Starred", icon: "star", group: .navigation) {
                coordinator.selectedFolder = .starred
            },
            Command(id: "folder.snoozed", title: "Go to Snoozed", icon: "clock.fill", group: .navigation) {
                coordinator.selectedFolder = .snoozed
            },
            Command(id: "settings.open", title: "Open Settings", icon: "gear", group: .actions) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
        ]
    }

    private func trackRecent(_ id: String) {
        recentCommandIDs.removeAll { $0 == id }
        recentCommandIDs.insert(id, at: 0)
        if recentCommandIDs.count > 5 { recentCommandIDs = Array(recentCommandIDs.prefix(5)) }
    }
}
