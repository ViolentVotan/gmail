import AppIntents

struct FlagEmailIntent: AppIntent {
    static let title: LocalizedStringResource = "Flag Email"
    static let description: IntentDescription = "Toggles the star/flag on an email in Vik"
    static let openAppWhenRun = false

    @Parameter(title: "Emails")
    var emails: [MailMessageEntity]

    @Parameter(title: "Flagged")
    var flagged: Bool

    func perform() async throws -> some IntentResult {
        try await IntentHelpers.performOnEach(emails) { messageId, accountID in
            try await GmailMessageService.shared.setStarred(flagged, id: messageId, accountID: accountID)
        }
        return .result()
    }
}
