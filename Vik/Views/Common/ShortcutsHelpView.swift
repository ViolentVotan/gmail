import SwiftUI

struct ShortcutsHelpView: View {

    private struct Shortcut {
        let keys: String
        let description: String
    }

    private let sections: [(title: String, shortcuts: [Shortcut])] = [
        ("Navigation", [
            Shortcut(keys: "↑ / ↓", description: "Previous / next email"),
            Shortcut(keys: "⌘1", description: "Switch to Mail"),
            Shortcut(keys: "⌘2", description: "Switch to Calendar"),
            Shortcut(keys: "⌘\\", description: "Toggle sidebar"),
            Shortcut(keys: "⌥⇥", description: "Cycle focus area"),
        ]),
        ("Actions", [
            Shortcut(keys: "⌘N", description: "New email"),
            Shortcut(keys: "⌘R", description: "Reply"),
            Shortcut(keys: "⌘⇧R", description: "Reply all"),
            Shortcut(keys: "⌘⇧F", description: "Forward"),
            Shortcut(keys: "E", description: "Archive"),
            Shortcut(keys: "⌫", description: "Move to Trash"),
            Shortcut(keys: "S", description: "Toggle star"),
            Shortcut(keys: "⌘L", description: "Toggle star (menu)"),
            Shortcut(keys: "U", description: "Mark as unread"),
            Shortcut(keys: "R", description: "Mark as read"),
            Shortcut(keys: "⌘⇧U", description: "Toggle read/unread"),
            Shortcut(keys: "⌘E", description: "Archive (menu)"),
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
        ("Calendar", [
            Shortcut(keys: "D", description: "Day view"),
            Shortcut(keys: "W", description: "Week view"),
            Shortcut(keys: "A", description: "Agenda view"),
            Shortcut(keys: "⌘T", description: "Go to today"),
            Shortcut(keys: "Y", description: "Accept event"),
            Shortcut(keys: "M", description: "Maybe / tentative"),
            Shortcut(keys: "N", description: "Decline event"),
            Shortcut(keys: "E", description: "Edit event"),
        ]),
        ("General", [
            Shortcut(keys: "⌘K", description: "Command palette"),
            Shortcut(keys: "⌘F", description: "Search"),
            Shortcut(keys: "⌘,", description: "Settings"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            ForEach(sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(section.title)
                        .font(Typography.captionSemibold)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .accessibilityAddTraits(.isHeader)

                    VStack(spacing: Spacing.xxs) {
                        ForEach(section.shortcuts, id: \.keys) { shortcut in
                            HStack {
                                Text(shortcut.description)
                                    .font(Typography.body)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(shortcut.keys)
                                    .font(Typography.subhead)
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.vertical, Spacing.xxs)
                                    .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.xs))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: CornerRadius.xs)
                                            .stroke(.separator, lineWidth: 1)
                                    )
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                            .background(.fill.quaternary.opacity(0.5))
                            .clipShape(.rect(cornerRadius: CornerRadius.sm))
                        }
                    }
                }
            }
        }
        .padding(Spacing.xl)
    }
}
