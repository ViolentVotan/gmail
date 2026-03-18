import AppIntents

struct VikShortcuts: AppShortcutsProvider {
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

        AppShortcut(
            intent: SendDraftIntent(),
            phrases: [
                "Send my draft in \(.applicationName)",
                "Send draft in \(.applicationName)",
            ],
            shortTitle: "Send Draft",
            systemImageName: "paperplane"
        )

        AppShortcut(
            intent: ReplyMailIntent(),
            phrases: [
                "Reply to email in \(.applicationName)",
                "Reply in \(.applicationName)",
            ],
            shortTitle: "Reply to Email",
            systemImageName: "arrowshape.turn.up.left"
        )

        AppShortcut(
            intent: ForwardMailIntent(),
            phrases: [
                "Forward email in \(.applicationName)",
                "Forward in \(.applicationName)",
            ],
            shortTitle: "Forward Email",
            systemImageName: "arrowshape.turn.up.right"
        )

        AppShortcut(
            intent: ShowUpcomingEventsIntent(),
            phrases: [
                "Show my upcoming events in \(.applicationName)",
                "What's on my calendar in \(.applicationName)",
            ],
            shortTitle: "Upcoming Events",
            systemImageName: "calendar"
        )

        AppShortcut(
            intent: CreateCalendarEventIntent(),
            phrases: [
                "Create a calendar event in \(.applicationName)",
                "Schedule an event in \(.applicationName)",
            ],
            shortTitle: "Create Event",
            systemImageName: "calendar.badge.plus"
        )

    }
}
