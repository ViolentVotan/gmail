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
            intent: DeleteDraftIntent(),
            phrases: [
                "Delete draft in \(.applicationName)",
                "Discard draft in \(.applicationName)",
            ],
            shortTitle: "Delete Draft",
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
            intent: ForwardMailIntent(),
            phrases: [
                "Forward email in \(.applicationName)",
                "Forward in \(.applicationName)",
            ],
            shortTitle: "Forward Email",
            systemImageName: "arrowshape.turn.up.right"
        )
    }
}
