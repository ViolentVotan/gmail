import AppIntents

struct SerifShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchEmailIntent(),
            phrases: [
                "Search emails in \(.applicationName)",
                "Find emails in \(.applicationName)",
                "Search my inbox in \(.applicationName)",
            ],
            shortTitle: "Search Emails",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: ComposeEmailIntent(),
            phrases: [
                "Compose email with \(.applicationName)",
                "New email in \(.applicationName)",
                "Write an email in \(.applicationName)",
            ],
            shortTitle: "Compose Email",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: OpenEmailIntent(),
            phrases: [
                "Open email in \(.applicationName)",
                "Show email in \(.applicationName)",
            ],
            shortTitle: "Open Email",
            systemImageName: "envelope.open"
        )

        AppShortcut(
            intent: MarkAsReadIntent(),
            phrases: [
                "Mark email as read in \(.applicationName)",
                "Mark as read in \(.applicationName)",
            ],
            shortTitle: "Mark as Read",
            systemImageName: "envelope.open.badge.clock"
        )
    }
}
