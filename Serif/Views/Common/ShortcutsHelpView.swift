import SwiftUI

struct ShortcutsHelpView: View {

    private struct Shortcut {
        let keys: String
        let description: String
    }

    private let sections: [(title: String, shortcuts: [Shortcut])] = [
        ("Navigation", [
            Shortcut(keys: "↑ / ↓", description: "Previous / next email"),
            Shortcut(keys: "⌘N", description: "New email"),
        ]),
        ("Actions", [
            Shortcut(keys: "E", description: "Archive"),
            Shortcut(keys: "⌫", description: "Move to Trash"),
            Shortcut(keys: "S", description: "Toggle star"),
            Shortcut(keys: "U", description: "Mark as unread"),
            Shortcut(keys: "R", description: "Mark as read"),
            Shortcut(keys: "⌘Z", description: "Undo last action"),
        ]),
        ("Selection", [
            Shortcut(keys: "⌘A", description: "Select all"),
            Shortcut(keys: "⌘+Click", description: "Toggle selection"),
            Shortcut(keys: "⇧+Click", description: "Range select"),
        ]),
        ("Composition", [
            Shortcut(keys: "⌘↵", description: "Send email"),
            Shortcut(keys: "Esc", description: "Discard reply"),
        ]),
        ("General", [
            Shortcut(keys: "⌘F", description: "Search"),
            Shortcut(keys: "⌘,", description: "Settings"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    VStack(spacing: 2) {
                        ForEach(section.shortcuts, id: \.keys) { shortcut in
                            HStack {
                                Text(shortcut.description)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(shortcut.keys)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.regularMaterial)
                                    .cornerRadius(5)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(.separator, lineWidth: 1)
                                    )
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.fill.quaternary.opacity(0.5))
                            .cornerRadius(7)
                        }
                    }
                }
            }
        }
        .padding(20)
    }
}
