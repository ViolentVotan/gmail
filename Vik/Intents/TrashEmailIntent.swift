import AppIntents

@AppIntent(schema: .mail.deleteMail)
struct TrashEmailIntent {
    static let openAppWhenRun = false

    @Parameter var entities: [MailMessageEntity]

    func perform() async throws -> some IntentResult {
        try await IntentHelpers.performOnEach(entities) { messageId, accountID in
            try await GmailMessageService.shared.trashMessage(id: messageId, accountID: accountID)
        }
        return .result()
    }
}
