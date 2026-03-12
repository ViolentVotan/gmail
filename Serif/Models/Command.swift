import Foundation

struct Command: Identifiable {
    let id: String  // Stable ID like "action.compose", "folder.inbox"
    let title: String
    let subtitle: String?
    let icon: String
    let group: PaletteCommandGroup
    let action: @Sendable @MainActor () -> Void

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: String,
        group: PaletteCommandGroup = .actions,
        action: @escaping @Sendable @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.group = group
        self.action = action
    }
}

enum PaletteCommandGroup: String, CaseIterable, Identifiable {
    case navigation = "Navigation"
    case actions = "Actions"
    case recent = "Recent"

    var id: String { rawValue }
}
