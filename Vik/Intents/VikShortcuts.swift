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
            intent: ReplyMailIntent(),
            phrases: [
                "Reply to email in \(.applicationName)",
                "Reply in \(.applicationName)",
            ],
            shortTitle: "Reply to Email",
            systemImageName: "arrowshape.turn.up.left"
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

        AppShortcut(
            intent: RSVPToEventIntent(),
            phrases: [
                "Respond to calendar event in \(.applicationName)",
                "RSVP to event in \(.applicationName)",
            ],
            shortTitle: "RSVP to Event",
            systemImageName: "hand.raised"
        )

        AppShortcut(
            intent: CheckAvailabilityIntent(),
            phrases: [
                "Check my availability in \(.applicationName)",
                "Am I free in \(.applicationName)",
            ],
            shortTitle: "Check Availability",
            systemImageName: "calendar.badge.checkmark"
        )

    }
}
