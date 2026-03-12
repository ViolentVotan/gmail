import AppIntents

struct MarkAsReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Email as Read"
    static let description: IntentDescription = "Marks an email as read in Serif"

    @Parameter(title: "Email")
    var email: EmailEntity

    func perform() async throws -> some IntentResult {
        // TODO: Needs account resolution — MailboxViewModel.markAsRead requires both
        // the Gmail message ID and the account ID, which cannot be determined from
        // EmailEntity alone without a mapping from message ID to account. Implement
        // once EmailEntity stores accountID or a lookup service is available.
        return .result()
    }
}
