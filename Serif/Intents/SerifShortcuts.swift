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
            intent: UpdateMailIntent(),
            phrases: [
                "Mark email as read in \(.applicationName)",
                "Mark as read in \(.applicationName)",
                "Update email in \(.applicationName)",
            ],
            shortTitle: "Update Email",
            systemImageName: "envelope.open.badge.clock"
        )

        AppShortcut(
            intent: ArchiveEmailIntent(),
            phrases: [
                "Archive email in \(.applicationName)",
                "Archive message in \(.applicationName)",
            ],
            shortTitle: "Archive Email",
            systemImageName: "archivebox"
        )

        AppShortcut(
            intent: FlagEmailIntent(),
            phrases: [
                "Flag email in \(.applicationName)",
                "Star email in \(.applicationName)",
            ],
            shortTitle: "Flag Email",
            systemImageName: "flag"
        )

        AppShortcut(
            intent: TrashEmailIntent(),
            phrases: [
                "Trash email in \(.applicationName)",
                "Delete email in \(.applicationName)",
                "Move email to trash in \(.applicationName)",
            ],
            shortTitle: "Trash Email",
            systemImageName: "trash"
        )
    }
}
